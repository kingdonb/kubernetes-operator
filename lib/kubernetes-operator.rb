#!/usr/local/bin/ruby

require 'k8s-client'
require 'yaml'
require 'yaml/store'
require 'json'


class KubernetesOperator

    def initialize(crdGroup, crdVersion, crdPlural)
        # parameter
        @crdGroup = crdGroup
        @crdVersion = crdVersion
        @crdPlural = crdPlural

        # default config
        @sleepTimer = 10

        # create cache
        @store = YAML::Store.new("#{@crdGroup}_#{@crdVersion}_#{@crdPlural}.yaml")

        # Kubeconfig
        puts '{leve: "info", message: "validate kube config"}'
        if File.exist?("#{Dir.home}/.kube/config")
            puts '{leve: "info", message: "found kubeconfig in home directory"}'
            @k8sclient = K8s::Client.config(
                K8s::Config.load_file(
                    File.expand_path '~/.kube/config'
                )
            )
        else
            puts '{leve: "info", message: "use in cluster configuration"}'
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

    def setDeleteMethod(callback)
        @deleteMethod = callback
    end

    def defaultActionMethod(obj,k8sclient)
        puts "{leve: \"info\", action: \"#{obj["metadata"]["crd_status"]}\", ressource: \"#{obj["metadata"]["namespace"]}/#{obj["metadata"]["name"]}\"}"
    end

    # Config Methods
    def setSleepTimer(nr)
       @sleepTimer = nr
    end

    def setScopeNamespaces(lst)
        @lstOfNamespaces = lst
    end


    # Controller
    def run

        @addMethod = method(:defaultActionMethod) unless @addMethod
        @updateMethod = method(:defaultActionMethod) unless @updateMethod
        @deleteMethod = method(:defaultActionMethod) unless @deleteMethod

        while true

            # Search for ressources
            _ressources = @k8sclient.api(@crdGroup+"/"+@crdVersion).resource(@crdPlural).list()

            _ressources.each do |_i|
                _uid = _i["metadata"]["uid"]
                _v = _i["metadata"]["resourceVersion"]

                if @lstOfNamespaces == nil || @lstOfNamespaces.contains(_i["metadata"]["namespace"])
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
                                @deleteMethod.call(_i,@k8sclient)
                            else
                                # store new version in cache
                                @store.transaction do
                                    @store[_uid] = _v
                                    @store.commit
                                end

                                # call the action method
                                _i["metadata"]["crd_status"] = "update"
                                @updateMethod.call(_i,@k8sclient)
                            end
                        end
                    end
                end
            end

            # Done
            sleep @sleepTimer

        end
    end
end



