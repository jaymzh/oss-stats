require 'rake/testtask'

desc 'Run tests'
Rake::TestTask.new(:test) do |t|
  t.libs << 'spec'
  t.test_files = FileList['spec/**/*_spec.rb']
  t.verbose = true
end

desc 'Run tests for configuration'
Rake::TestTask.new(:test_config) do |t|
  t.libs << 'spec'
  t.test_files = FileList['spec/*config*_spec.rb']
  t.verbose = true
end

task default: :test