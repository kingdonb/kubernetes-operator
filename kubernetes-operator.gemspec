Gem::Specification.new do |s|
    s.name	= 'kubernetes-operator'
    s.version	= '0.0.1'
    s.platform    = Gem::Platform::RUBY
    s.summary	= "lib"
    s.description	= "Libary to create an kubernetes operator with ruby"
    s.author	= "Tobias Kuntzsch"
    s.email	= "mail@tobiaskuntzsch.de"
    s.homepage	= "https://gitlab.com/tobiaskuntzsch/kubernetes-operator"
    s.files	=  Dir['README.md', '{bin,lib,config,vendor}/**/*'] # 'VERSION', 'Gemfile', 'Rakefile', 
    s.require_path = 'lib'
    #s.add_dependency('yaml/store')
    s.add_dependency('k8s-client')
    #s.add_dependency('json')
    #s.add_dependency('yaml')
  end
