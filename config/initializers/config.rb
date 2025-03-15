# Config gem configuration
require 'config'

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
