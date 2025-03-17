#!/usr/bin/env ruby
#
# Configuration validation helper
# Usage: ruby scripts/validate_config.rb path/to/config.yml
#

require 'yaml'

# Add optional test mode flag
ENV['CHEF_OSS_STATS_TEST_MODE'] = 'true'

# First load the schema validator
require_relative '../config/initializers/schema_validator'

# Get filename from command line
config_file = ARGV[0]

unless config_file
  puts 'ERROR: Please provide a configuration file path'
  puts 'Usage: ruby scripts/validate_config.rb path/to/config.yml'
  exit(1)
end

unless File.exist?(config_file)
  puts "ERROR: File '#{config_file}' does not exist"
  exit(1)
end

begin
  # Load the YAML file
  puts "Loading configuration from #{config_file}..."
  config = YAML.load_file(config_file)

  # Validate the configuration
  puts 'Validating configuration...'
  errors = SchemaValidator.validate_config(config)

  if errors.empty?
    puts '✅ Configuration is valid!'
    exit(0)
  else
    puts '❌ Configuration validation failed!'
    puts errors.map { |e| "  - #{e}" }.join("\n")
    exit(1)
  end
rescue => e
  puts "ERROR: #{e.message}"
  exit(1)
end
