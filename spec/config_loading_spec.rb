#!/usr/bin/env ruby
# This is a test for the configuration loading in chef_ci_status.rb

require 'minitest/autorun'
require 'yaml'
require 'tempfile'

# Add lib directory to load path
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

class ConfigLoadingTest < Minitest::Test
  def setup
    # Create a temporary config file
    @temp_config = Tempfile.new(['test_config', '.yml'])
    @temp_config.write(<<~YAML)
      default_org: 'test-org'
      default_repo: 'test-repo'
      default_branches: 
        - 'test-branch'
      default_days: 15
      default_mode: 'ci'
      
      organizations:
        test-org:
          name: 'Test Organization'
          repositories:
            - name: 'test-repo'
              branches: ['test-branch']
    YAML
    @temp_config.close
  end
  
  def teardown
    @temp_config.unlink
  end
  
  def test_custom_config_loading
    # This is a simple test to check if the script can load a custom config
    # The help command uses the defaults from Settings, not from --config
    # So we'll just check that the config file is loaded without errors
    output = `ruby #{File.expand_path('../src/chef_ci_status.rb', __dir__)} --config #{@temp_config.path} --help`
    
    # Verify the config was loaded
    assert_match(/Loaded custom configuration from/, output, 
                "Custom config not loaded")
    refute_match(/Warning: Config file.*not found/, output,
                "Unexpected warning about config file not found")
    refute_match(/Error loading custom configuration/, output, 
                "Error loading custom configuration")
  end
  
  def test_fallback_to_defaults
    # Test that the script falls back to defaults when config isn't found
    # We use a non-existent file path
    output = `ruby #{File.expand_path('../src/chef_ci_status.rb', __dir__)} --config /nonexistent/path.yml --help`
    
    # Verify the output contains default values
    assert_match(/Warning: Config file \/nonexistent\/path.yml not found/, output,
                 "Missing warning about non-existent config file")
    assert_match(/--org ORG\s+GitHub org name \(default: chef\)/, output,
                 "Default org not used as fallback")
  end
end