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

    # Logger Methods
    def getLogger()
        return @logger
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
                                # add finalizer
                                @logger.info("add finalizer to #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                patched = @k8sclient.patch_entity(@crdPlural,notice[:object][:metadata][:name], {metadata: {finalizers: ["#{@crdPlural}.#{@crdVersion}.#{@crdGroup}"]}},'merge-patch',@options[:namespace])
                                # trigger action
                                @logger.info("trigger add action for #{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]})")
                                resp = @addMethod.call(notice[:object],@k8sclient)
                                # update status
                                if resp[:status]
                                    @k8sclient.patch_entity(@crdPlural,notice[:object][:metadata][:name]+"/status", {status: resp[:status]},'merge-patch',@options[:namespace])
                                end
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
                            if isCached != notice[:object][:metadata][:resourceVersion]
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
                            @logger.info("#{notice[:object][:metadata][:name]} (#{notice[:object][:metadata][:uid]}) is done")
                        else
                            @logger.info("strange things are going on here, I found the type "+notice[:type])
                        end
                    rescue => exception
                        @logger.error(exception.inspect)
                    end
                end
                watcher.finish

                ## Search for ressources
                #_ressources = @k8sclient.get(@crdGroup+"/"+@crdVersion).resource(@crdPlural).list()

                #_ressources.each do |_i|
                #    _uid = _i["metadata"]["uid"]
                #    _v = _i["metadata"]["resourceVersion"]

                #    if @options[:namespace] == nil || @options[:namespace].contains(_i["metadata"]["namespace"])
                #        _from_cache = @store.transaction{@store[_uid]}

                #        unless _from_cache
                #            # Add finalizer and refresh version number
                #            _i[:metadata][:finalizers] = ["#{@crdPlural}.#{@crdVersion}.#{@crdGroup}"]
                #            _i = @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).update_resource(_i)

                #            # call the action method
                #            _i["metadata"]["crd_status"] = "add"
                #            @logger.info("add custom resource #{_i["metadata"]["name"]}@#{_i["metadata"]["namespace"]}") if _i["metadata"]["namespace"]
                #            @logger.info("add custom resource #{_i["metadata"]["name"]}@cluster") unless _i["metadata"]["namespace"]
                #            @addMethod.call(_i,@k8sclient)

                #            # update status
                #            _i[:status] = {message: "Test"}
                #            _i = @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).update_resource(_i)

                #            # Cache last version of ressources
                #            @store.transaction do
                #                @store[_uid] = _i["metadata"]["resourceVersion"]
                #                @store.commit
                #            end

                #        else
                #            # only trigger action on change or delete event
                #            unless _from_cache == _v
                #                if _i["metadata"]["deletionTimestamp"]
                #                    # remove finalizers
                #                    _i[:metadata][:finalizers] = []
                #                    @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).update_resource(_i)

                #                    # call the action method
                #                    _i["metadata"]["crd_status"] = "delete"
                #                    @logger.info("delete custom resource #{_i["metadata"]["name"]}@#{_i["metadata"]["namespace"]}") if _i["metadata"]["namespace"]
                #                    @logger.info("delete custom resource #{_i["metadata"]["name"]}@cluster") unless _i["metadata"]["namespace"]
                #                    @deleteMethod.call(_i,@k8sclient)
                #                else
                #                    # store new version in cache
                #                    @store.transaction do
                #                        @store[_uid] = _v
                #                        @store.commit
                #                    end

                #                    # call the action method
                #                    _i["metadata"]["crd_status"] = "update"
                #                    @logger.info("update custom resource #{_i["metadata"]["name"]}@#{_i["metadata"]["namespace"]}") if _i["metadata"]["namespace"]
                #                    @logger.info("update custom resource #{_i["metadata"]["name"]}@cluster") unless _i["metadata"]["namespace"]
                #                    @updateMethod.call(_i,@k8sclient)
                #                end
                #            end
                #        end
                #    end
                #end

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




