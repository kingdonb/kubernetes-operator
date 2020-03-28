#!/usr/local/bin/ruby

## kubernetes
require 'k8s-client'

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
            @k8sclient = K8s::Client.config(
                K8s::Config.load_file(
                    File.expand_path '~/.kube/config'
                )
            )
        else
            @k8sclient = K8s::Client.in_cluster_config
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

                # Search for ressources
                _ressources = @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).list()

                _ressources.each do |_i|
                    _uid = _i["metadata"]["uid"]
                    _v = _i["metadata"]["resourceVersion"]

                    if @options[:namespace] == nil || @options[:namespace].contains(_i["metadata"]["namespace"])
                        _from_cache = @store.transaction{@store[_uid]}

                        unless _from_cache
                            # Add finalizer and refresh version number
                            _i[:metadata][:finalizers] = ["#{@crdPlural}.#{@crdVersion}.#{@crdGroup}"]
                            _i2 = @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).update_resource(_i)
                            _v = _i2["metadata"]["resourceVersion"]

                            # Cache last version of ressources
                            @store.transaction do
                                @store[_uid] = _v
                                @store.commit
                            end

                            # call the action method
                            _i["metadata"]["crd_status"] = "add"
                            @logger.info("add custom resource #{_i["metadata"]["name"]}@#{_i["metadata"]["namespace"]}") if _i["metadata"]["namespace"]
                            @logger.info("add custom resource #{_i["metadata"]["name"]}@cluster") unless _i["metadata"]["namespace"]
                            @addMethod.call(_i,@k8sclient)
                        else
                            # only trigger action on change or delete event
                            unless _from_cache == _v
                                if _i["metadata"]["deletionTimestamp"]
                                    # remove finalizers
                                    _i[:metadata][:finalizers] = []
                                    @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).update_resource(_i)

                                    # call the action method
                                    _i["metadata"]["crd_status"] = "delete"
                                    @logger.info("delete custom resource #{_i["metadata"]["name"]}@#{_i["metadata"]["namespace"]}") if _i["metadata"]["namespace"]
                                    @logger.info("delete custom resource #{_i["metadata"]["name"]}@cluster") unless _i["metadata"]["namespace"]
                                    @deleteMethod.call(_i,@k8sclient)
                                else
                                    # store new version in cache
                                    @store.transaction do
                                        @store[_uid] = _v
                                        @store.commit
                                    end

                                    # call the action method
                                    _i["metadata"]["crd_status"] = "update"
                                    @logger.info("update custom resource #{_i["metadata"]["name"]}@#{_i["metadata"]["namespace"]}") if _i["metadata"]["namespace"]
                                    @logger.info("update custom resource #{_i["metadata"]["name"]}@cluster") unless _i["metadata"]["namespace"]
                                    @updateMethod.call(_i,@k8sclient)
                                end
                            end
                        end
                    end
                end

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




