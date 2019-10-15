# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "github_workflow/version"

Gem::Specification.new do |spec|
  spec.name          = "github_workflow"
  spec.version       = GithubWorkflow::VERSION
  spec.authors       = ["Ben Liscio"]
  spec.email         = ["bliscio@daisybill.com"]

  spec.summary       = %q{DaisyBill's internal github workflows}
  spec.homepage      = "https://github.com/daisybill/github_workflow"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 0.19"
  spec.add_dependency "faraday", "~> 0.11"
  spec.add_dependency "terminal-table", "~> 1.5"
  spec.add_dependency "ruby-trello", "~> 2.1"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "rake", "~> 10.0"
end
