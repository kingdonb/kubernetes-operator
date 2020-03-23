# example usage
crdGroup = "familykuntzsch.de"
crdVersion = "v1alpha1"
crdPlural = "fuconfigs"

def my_custom_action(obj,k8sclient)
    puts "==> Im cool as fu (#{obj["metadata"]["crd_status"]} of #{obj["metadata"]["name"]})"
end

opi = KubernetesOperator.new(crdGroup,crdVersion,crdPlural)
opi.setAddMethod(method(:my_custom_action))
opi.run()