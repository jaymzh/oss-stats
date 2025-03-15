require 'rake/testtask'

desc 'Run tests with appropriate environment variables'
task :test do
  # Set environment variables for testing
  ENV['CHEF_OSS_STATS_TEST_MODE'] = 'true'
  ENV['CHEF_OSS_STATS_IGNORE_CONFIG_ERRORS'] = 'true'
  
  # Run the actual tests
  Rake::Task['run_tests'].invoke
end

desc 'Run configuration tests with appropriate environment variables'
task :test_config do
  # Set environment variables for testing
  ENV['CHEF_OSS_STATS_TEST_MODE'] = 'true'
  ENV['CHEF_OSS_STATS_IGNORE_CONFIG_ERRORS'] = 'true'
  
  # Run the configuration tests
  Rake::Task['run_config_tests'].invoke
end

# Actual test runner tasks (not directly called)
Rake::TestTask.new(:run_tests) do |t|
  t.libs << 'spec'
  t.test_files = FileList['spec/**/*_spec.rb']
  t.verbose = true
end

Rake::TestTask.new(:run_config_tests) do |t|
  t.libs << 'spec'
  t.test_files = FileList['spec/*config*_spec.rb']
  t.verbose = true
end

task default: :test