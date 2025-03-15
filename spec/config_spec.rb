#!/usr/bin/env ruby
# This is a simple test script for the configuration system.
# It doesn't use any specific test framework to avoid imposing one.

require 'minitest/autorun'
require 'yaml'

# Path to the test configuration
TEST_CONFIG_PATH = File.expand_path('../config/settings.yml', __dir__)

class ConfigTest < Minitest::Test
  def test_config_file_exists
    assert File.exist?(TEST_CONFIG_PATH), "Configuration file not found at #{TEST_CONFIG_PATH}"
  end
  
  def test_config_file_contains_required_keys
    config = YAML.load_file(TEST_CONFIG_PATH)
    
    # Test for required top-level keys
    assert config.key?('default_org'), "Missing 'default_org' in configuration"
    assert config.key?('default_repo'), "Missing 'default_repo' in configuration"
    assert config.key?('default_branches'), "Missing 'default_branches' in configuration"
    assert config.key?('default_days'), "Missing 'default_days' in configuration"
    assert config.key?('default_mode'), "Missing 'default_mode' in configuration"
    
    # Test for organizations structure
    assert config.key?('organizations'), "Missing 'organizations' in configuration"
    assert config['organizations'].key?('chef'), "Missing 'chef' in organizations"
    assert config['organizations']['chef'].key?('repositories'), "Missing 'repositories' in chef organization"
  end
  
  def test_default_values
    config = YAML.load_file(TEST_CONFIG_PATH)
    
    # Test default values
    assert_equal 'chef', config['default_org'], "Incorrect default_org value"
    assert_equal 'chef', config['default_repo'], "Incorrect default_repo value"
    assert_includes config['default_branches'], 'main', "default_branches should include 'main'"
    assert_equal 30, config['default_days'], "Incorrect default_days value"
    assert_equal 'all', config['default_mode'], "Incorrect default_mode value"
  end
  
  def test_organization_structure
    config = YAML.load_file(TEST_CONFIG_PATH)
    
    chef_repos = config['organizations']['chef']['repositories']
    assert chef_repos.is_a?(Array), "Repositories should be an array"
    
    # Test for at least one repository
    refute_empty chef_repos, "Chef repositories should not be empty"
    
    # Test repository structure
    repo = chef_repos.first
    assert repo.key?('name'), "Repository missing 'name' field"
    assert repo.key?('branches'), "Repository missing 'branches' field"
    assert repo['branches'].is_a?(Array), "Repository branches should be an array"
  end
end