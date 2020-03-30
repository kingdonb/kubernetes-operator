#!/usr/local/bin/ruby

require 'kubernetes-operator'

crdGroup = "example.com"
crdVersion = "v1alpha1"
crdPlural = "fancy-ruby-samples"

def upsert(obj,k8sclient)
    @logger.info("create new fancy sample with the name #{obj["spec"]["sampleName"]}")
    @eventHelper.add(obj,"fancy sample event")
    {:status => {:message => "upsert works fine"}}
end

def delete(obj,k8sclient)
    @logger.info("delete fancy sample with the name #{obj["spec"]["sampleName"]}")
end

opi = KubernetesOperator.new(crdGroup,crdVersion,crdPlural)
@logger = opi.getLogger()
@eventHelper = opi.getEventHelper()
opi.setUpsertMethod(method(:upsert))
opi.setDeleteMethod(method(:delete))
opi.run()
