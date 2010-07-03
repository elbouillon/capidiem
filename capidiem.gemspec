Gem::Specification.new do |spec|

  spec.name = 'capidiem'
  spec.version = '0.0.2'
  spec.platform = Gem::Platform::RUBY
  spec.description = <<-DESC
    Capistrano is an open source tool for running scripts on multiple servers. It’s primary use is for easily deploying applications. While it was built specifically for deploying Rails apps, it’s pretty simple to customize it to deploy other types of applications. This package is a deployment “recipe” to work with diem PHP applications.
  DESC
  spec.summary = <<-DESC.strip.gsub(/\n\s+/, " ")
    Deploying diem PHP applications with Capistrano.
  DESC

  spec.files = Dir.glob("{bin,lib}/**/*") + %w(README.md LICENSE CHANGELOG)
  spec.require_path = 'lib'
  spec.has_rdoc = false

  spec.bindir = "bin"
  spec.executables << "capidiem"

  spec.add_dependency 'capistrano', ">= 2.5.10"

  spec.authors =  ["Konstantin Kudryashov", "Mickael Kurmann"]
  spec.email =    ["ever.zet@gmail.com", "mickael.kurmann@gmail.com"]
  spec.homepage = "http://github.com/elbouillon/capidiem"
  spec.rubyforge_project = "capidiem"

end
