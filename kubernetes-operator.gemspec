Gem::Specification.new do |s|
    s.name	= 'kubernetes-operator'
    s.version	= '0.0.4'
    s.platform    = Gem::Platform::RUBY
    s.summary	= "lib"
    s.description	= "Libary to create an kubernetes operator with ruby"
    s.author	= "Tobias Kuntzsch"
    s.email	= "mail@tobiaskuntzsch.de"
    s.homepage	= "https://gitlab.com/tobiaskuntzsch/kubernetes-operator"
    s.files	=  Dir['README.md', '{bin,lib,config,vendor}/**/*'] # 'VERSION', 'Gemfile', 'Rakefile', 
    s.require_path = 'lib'

    s.add_dependency('kubeclient')
    s.add_dependency('log4r')
    s.add_dependency('log_formatter')

end