# Ruby Kubernetes Operator
If you do not want to create your operators for kubernetes in golang, it is difficult to find good frameworks. This gem is used to implement a few basic functions and to quickly create your own operators based on ruby. It is not a framework, so the YAML CRDs still have to be created by hand.

## How it works?
- Watch changes on CR.
- Trigger Actions for Add,Update or Delete
- Handle the finalizer on create and after delete

![KubernetesOperator.png](KubernetesOperator.png)

## Installation
The gem is hosted on [rubygems.org](https://rubygems.org/gems/kubernetes-operator), so you can install it with ...
```
gem install kubernetes-operator
```
... or with bundler in your Gemfile.

## Example

```
crdGroup = "exmaple.com"
crdVersion = "v1alpha1"
crdPlural = "myres"

def my_custom_action(obj,k8sclient)
    puts "Do some cool stuff for #{obj["metadata"]["crd_status"]} action of #{obj["metadata"]["name"]}"
end

opi = KubernetesOperator.new(crdGroup,crdVersion,crdPlural)
opi.setAddMethod(method(:my_custom_action))
opi.run()
```