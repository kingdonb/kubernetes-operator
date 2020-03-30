#!/usr/local/bin/ruby

## kubernetes
require 'kubeclient'

## storage
require 'yaml'
require 'yaml/store'

## logging
require 'log4r'
require 'log_formatter'
require 'log_formatter/log4r_json_formatter'
require 'json'

class EventHelper

    def initialize(logger,store)
        # logging
        @logger = logger
        @store = store

        # kubeconfig
        # we need our own client because its an different api path
        # (for local development it's nice to use .kube/config)
        if File.exist?("#{Dir.home}/.kube/config")
            config = Kubeclient::Config.read(ENV['KUBECONFIG'] || "#{ENV['HOME']}/.kube/config")
            context = config.context
            @k8sclient = Kubeclient::Client.new(
                context.api_endpoint,
                'v1',
                ssl_options: context.ssl_options,
                auth_options: context.auth_options
            )
        else
            auth_options = {
                bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token'
            }
            ssl_options = {}
            if File.exist?("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
                ssl_options[:ca_file] = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            end
            @k8sclient = Kubeclient::Client.new(
                'https://kubernetes.default.svc',
                'v1',
                auth_options: auth_options,
                ssl_options:  ssl_options
            )
        end
    end

    def add(obj,message,reason = "Upsert",type = "Normal", component = "KubernetesOperator")
        begin
            event = Kubeclient::Resource.new
            time = Time.new.utc

            _tmpNS = obj[:metadata][:namespace]

            event.firstTimestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ")
            event.lastTimestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ")
            event.involvedObject = {}
            event.involvedObject.apiVersion = obj[:apiVersion]
            event.involvedObject.kind = obj[:kind]
            event.involvedObject.name = obj[:metadata][:name]
            event.involvedObject.namespace = obj[:metadata][:namespace]
            event.involvedObject.resourceVersion = obj[:metadata][:resourceVersion]
            event.involvedObject.uid = obj[:metadata][:uid]
            event.kind = "Event"
            event.message = message
            event.metadata = {}
            event.metadata.name = "#{obj[:metadata][:name]}.#{time.to_i}"
            event.metadata.namespace = obj[:metadata][:namespace] ||= "default"
            event.reason = reason
            event.source = {}
            event.source.component = component
            event.type = type

            @k8sclient.create_event(event)

            @logger.info("add event #{message}(#{type}) to #{obj[:metadata][:name]}(#{obj[:metadata][:uid]})")
        rescue => exception
            @logger.error(exception.inspect)
        end

    end

    def deleteAll(obj)
        begin
            events = @k8sclient.get_events(namespace: obj[:metadata][:namespace],field_selector: "involvedObject.uid=#{obj[:metadata][:uid]}")
            events.each do |event|
                @logger.info("delete event #{event[:metadata][:name]}(#{event[:metadata][:namespace]}) from #{obj[:metadata][:name]}(#{obj[:metadata][:uid]})")
                @k8sclient.delete_event(event[:metadata][:name],event[:metadata][:namespace])
            end
        rescue => exception
            @logger.error(exception.inspect)
        end
    end
end

class KubernetesOperator

    def initialize(crdGroup, crdVersion, crdPlural, options = {} )
        # parameter
        @crdGroup = crdGroup
        @crdVersion = crdVersion
        @crdPlural = crdPlural

        # default config
        @options = options
        @options[:sleepTimer] ||= 10
        @options[:namespace] ||= nil

        # create persistence
        @options[:persistence_location] ||= "/tmp/persistence"
        Dir.mkdir(@options[:persistence_location]) unless File.exists?(@options[:persistence_location])
        @store = YAML::Store.new("#{@options[:persistence_location]}/#{@crdGroup}_#{@crdVersion}_#{@crdPlural}.yaml")

        # logging
        @logger = Log4r::Logger.new('Log4RTest')
        outputter = Log4r::StdoutOutputter.new(
            "console",
            :formatter => Log4r::JSONFormatter::Base.new("#{crdPlural}.#{@crdGroup}/#{@crdVersion}")
        )
        @logger.add(outputter)

        # kubeconfig
        # (for local development it's nice to use .kube/config)
        if File.exist?("#{Dir.home}/.kube/config")
            @logger.info("use local kube config")
            config = Kubeclient::Config.read(ENV['KUBECONFIG'] || "#{ENV['HOME']}/.kube/config")
            context = config.context
            @k8sclient = Kubeclient::Client.new(
                context.api_endpoint+"/apis/"+@crdGroup,
                @crdVersion,
                ssl_options: context.ssl_options,
                auth_options: context.auth_options
            )
        else
            @logger.info("use incluster config")
            auth_options = {
                bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token'
            }
            ssl_options = {}
            if File.exist?("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
                ssl_options[:ca_file] = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            end
            @k8sclient = Kubeclient::Client.new(
                'https://kubernetes.default.svc/apis/'+@crdGroup,
                @crdVersion,
                auth_options: auth_options,
                ssl_options:  ssl_options
            )
        end

        # event helper
        @eventHelper = EventHelper.new(@logger,@store)
    end

    # Action Methods
    def setAddMethod(callback)
        @addMethod = callback
    end

    def setUpdateMethod(callback)
        @updateMethod = callback
    end

    def setUpsertMethod(callback)
        @updateMethod = callback
        @addMethod = callback
    end

    def setDeleteMethod(callback)
        @deleteMethod = callback
    end

    # Helper Methods
    def getLogger()
        return @logger
    end

    def getEventHelper()
        return @eventHelper
    end

    # Controller
    def run
        @logger.info("start the operator")
        # load methods
        @addMethod = method(:defaultActionMethod) unless @addMethod
        @updateMethod = method(:defaultActionMethod) unless @updateMethod
        @deleteMethod = method(:defaultActionMethod) unless @deleteMethod

        while true

            begin
                if @options[:namespace]
                    watcher = @k8sclient.watch_entities(@crdPlural,@options[:namespace])
                else
                    watcher = @k8sclient.watch_entities(@crdPlural)
                end
                watcher.each do |notice|
                    begin
                        isCached = @store.transaction{@store[notice[:object][:metadata][:uid]]}
                        case notice[:type]
                        # new cr was added
                        when "ADDED"
                            # check if version is already processed
                            unless isCached
                                # trigger action
                                @logger.info("trigger add action for #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                resp = @addMethod.call(notice[:object],@k8sclient)
                                # update status
                                if resp[:status]
                                    @k8sclient.patch_entity(@crdPlural,notice[:object][:metadata][:name]+"/status", {status: resp[:status]},'merge-patch',@options[:namespace])
                                end
                                # add finalizer
                                @logger.info("add finalizer to #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                patched = @k8sclient.patch_entity(@crdPlural,notice[:object][:metadata][:name], {metadata: {finalizers: ["#{@crdPlural}.#{@crdVersion}.#{@crdGroup}"]}},'merge-patch',@options[:namespace])
                                # save version
                                @store.transaction do
                                    @store[patched[:metadata][:uid]] = patched[:metadata][:resourceVersion]
                                    @store.commit
                                end
                            else
                                @logger.info("skip add action for #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]}), found version in cache")
                            end
                        # cr was change or deleted (if finalizer is set, it an modified call, not an delete)
                        when "MODIFIED"
                            # check if version is already processed
                            if isCached.to_i < notice[:object][:metadata][:resourceVersion].to_i
                                # check if it's an delete event
                                unless notice[:object][:metadata][:deletionTimestamp]
                                    # trigger action
                                    @logger.info("trigger update action for #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                    resp = @updateMethod.call(notice[:object],@k8sclient)
                                    # update status
                                    if resp[:status]
                                        @k8sclient.patch_entity(@crdPlural,notice[:object][:metadata][:name]+"/status", {status: resp[:status]},'merge-patch',@options[:namespace])
                                    end
                                    # save version
                                    @store.transaction do
                                        @store[notice[:object][:metadata][:uid]] = notice[:object][:metadata][:resourceVersion]
                                        @store.commit
                                    end
                                else
                                    # trigger action
                                    @logger.info("trigger delete action for #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                    @updateMethod.call(notice[:object],@k8sclient)
                                    # remove finalizer
                                    @logger.info("remove finalizer to #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                    patched = @k8sclient.patch_entity(@crdPlural,notice[:object][:metadata][:name], {metadata: {finalizers: nil}},'merge-patch',@options[:namespace])
                                end
                            else
                                @logger.info("skip update action for #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]}), found version in cache")
                            end
                        when "DELETED"
                            @logger.info("#{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]}) is done, clean up events")
                            @eventHelper.deleteAll(notice[:object])
                        else
                            @logger.info("strange things are going on here, I found the type "+notice[:type])
                        end
                    rescue => exception
                        @logger.error(exception.inspect)
                    end
                end
                watcher.finish

            rescue => exception
                @logger.error(exception.inspect)
            end

            # Done
            sleep @options[:sleepTimer]

        end
    end

    private
        def defaultActionMethod(obj,k8sclient)
            puts "{leve: \"info\", action: \"#{obj["metadata"]["crd_status"]}\", ressource: \"#{obj["metadata"]["namespace"]}/#{obj["metadata"]["name"]}\"}"
        end
end




