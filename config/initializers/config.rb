# Config gem configuration
require 'config'
require_relative 'schema_validator'

Config.setup do |config|
  # Name of the constant exposing loaded settings
  config.const_name = 'Settings'

  # Ability to remove elements of the array set in earlier loaded settings file
  config.knockout_prefix = nil

  # Load configuration files in this order:
  # 1. settings.yml - Default settings
  # 2. settings.local.yml - Local overrides (optional, gitignored)
  config.use_env = false
  config.env_prefix = 'CHEF_OSS_STATS'
  config.env_separator = '__'

  # Define the config file paths
  config.load_and_set_settings(
    # Default settings
    File.join(File.dirname(__FILE__), '..', 'settings.yml'),
    # Optional local settings file (for development/testing)
    File.join(File.dirname(__FILE__), '..', 'settings.local.yml'),
  )
end

# Validate configuration
begin
  SchemaValidator.validate!(Settings)
rescue SchemaValidator::ConfigurationError => e
  puts 'ERROR: Configuration validation failed!'
  puts e.message
  exit(1) unless ENV['CHEF_OSS_STATS_IGNORE_CONFIG_ERRORS'] == 'true'
  puts 'Continuing despite errors due to CHEF_OSS_STATS_IGNORE_CONFIG_ERRORS=true'
end
