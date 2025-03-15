#!/usr/bin/env ruby
# Tests for the configuration validation system

require 'minitest/autorun'
require 'yaml'
require 'tempfile'

# Set test mode to avoid strict validation in tests
ENV['CHEF_OSS_STATS_TEST_MODE'] = 'true'

# Directly require the validator
require_relative '../config/initializers/schema_validator'

class ConfigValidationTest < Minitest::Test
  def setup
    # Create a valid config for testing
    @valid_config = {
      'default_org' => 'test-org',
      'default_repo' => 'test-repo',
      'default_branches' => ['main'],
      'default_days' => 30,
      'default_mode' => 'all',
      'organizations' => {
        'test-org' => {
          'name' => 'Test Organization',
          'repositories' => [
            {
              'name' => 'test-repo',
              'branches' => ['main']
            }
          ]
        }
      }
    }
  end

  def test_valid_config_passes_validation
    # Test that a valid config passes validation
    errors = SchemaValidator.validate_config(@valid_config)
    assert_empty errors, "Valid config should pass validation"
  end

  def test_missing_required_keys
    # Test validation fails when required keys are missing
    invalid_config = @valid_config.dup
    invalid_config.delete('default_org')
    invalid_config.delete('default_repo')
    
    errors = SchemaValidator.validate_config(invalid_config)
    refute_empty errors, "Missing required keys should fail validation"
    
    # Check specific error message
    assert_match(/Missing required configuration keys/, errors.join(' '), 
                "Should report missing required keys")
    assert_match(/default_org/, errors.join(' '), 
                "Should identify missing default_org")
    assert_match(/default_repo/, errors.join(' '), 
                "Should identify missing default_repo")
  end

  def test_invalid_types
    # Test validation fails when values have wrong types
    invalid_config = @valid_config.dup
    invalid_config['default_org'] = 123 # Should be a string
    invalid_config['default_days'] = 'thirty' # Should be a number
    invalid_config['default_branches'] = 'main' # Should be an array
    
    errors = SchemaValidator.validate_config(invalid_config)
    refute_empty errors, "Invalid types should fail validation"
    
    # Check specific error messages
    assert_match(/default_org must be a string/, errors.join(' '), 
                "Should identify wrong type for default_org")
    assert_match(/default_days must be a number/, errors.join(' '), 
                "Should identify wrong type for default_days")
    assert_match(/default_branches must be an array/, errors.join(' '), 
                "Should identify wrong type for default_branches")
  end

  def test_invalid_organization_structure
    # In test mode, organizations aren't required or deeply validated
    # So we'll temporarily unset the test mode to check organization validation
    old_test_mode = ENV['CHEF_OSS_STATS_TEST_MODE']
    ENV['CHEF_OSS_STATS_TEST_MODE'] = nil
    
    begin
      # Test validation fails when organization structure is invalid
      invalid_config = @valid_config.dup
      invalid_config['organizations'] = 'not-a-hash'
      
      errors = SchemaValidator.validate_config(invalid_config)
      refute_empty errors, "Invalid organization structure should fail validation"
      
      # Check specific error message
      assert_match(/organizations must be a hash/, errors.join(' '), 
                  "Should identify wrong type for organizations")
    ensure
      # Restore test mode
      ENV['CHEF_OSS_STATS_TEST_MODE'] = old_test_mode
    end
  end

  def test_invalid_repository_structure
    # In test mode, organization structure isn't validated
    # So we'll temporarily unset the test mode
    old_test_mode = ENV['CHEF_OSS_STATS_TEST_MODE']
    ENV['CHEF_OSS_STATS_TEST_MODE'] = nil
    
    begin
      # Test validation fails when repository structure is invalid
      invalid_config = @valid_config.dup
      invalid_config['organizations']['test-org']['repositories'] = 'not-an-array'
      
      errors = SchemaValidator.validate_config(invalid_config)
      refute_empty errors, "Invalid repository structure should fail validation"
      
      # Check specific error message
      assert_match(/repositories must be an array/, errors.join(' '), 
                  "Should identify wrong type for repositories")
    ensure
      # Restore test mode
      ENV['CHEF_OSS_STATS_TEST_MODE'] = old_test_mode
    end
  end

  def test_missing_repository_keys
    # In test mode, organization structure isn't validated
    # So we'll temporarily unset the test mode
    old_test_mode = ENV['CHEF_OSS_STATS_TEST_MODE']
    ENV['CHEF_OSS_STATS_TEST_MODE'] = nil
    
    begin
      # Test validation fails when repository is missing required keys
      invalid_config = @valid_config.dup
      invalid_config['organizations']['test-org']['repositories'] = [
        {
          # Missing 'name' key
          'branches' => ['main']
        }
      ]
      
      errors = SchemaValidator.validate_config(invalid_config)
      refute_empty errors, "Repository missing required keys should fail validation"
      
      # Check specific error message
      assert_match(/missing 'name'/, errors.join(' '), 
                  "Should identify missing name in repository")
    ensure
      # Restore test mode
      ENV['CHEF_OSS_STATS_TEST_MODE'] = old_test_mode
    end
  end

  def test_invalid_branch_structure
    # In test mode, organization structure isn't validated
    # So we'll temporarily unset the test mode
    old_test_mode = ENV['CHEF_OSS_STATS_TEST_MODE']
    ENV['CHEF_OSS_STATS_TEST_MODE'] = nil
    
    begin
      # Test validation fails when branches is not an array
      invalid_config = @valid_config.dup
      invalid_config['organizations']['test-org']['repositories'][0]['branches'] = 'main'
      
      errors = SchemaValidator.validate_config(invalid_config)
      refute_empty errors, "Invalid branch structure should fail validation"
      
      # Check specific error message - the exact message might vary
      assert_match(/branches must be an array|must be an array/, errors.join(' '), 
                  "Should identify wrong type for branches")
    ensure
      # Restore test mode
      ENV['CHEF_OSS_STATS_TEST_MODE'] = old_test_mode
    end
  end

  def test_handles_nil_config
    # Test validation handles nil config
    errors = SchemaValidator.validate_config(nil)
    refute_empty errors, "Nil config should fail validation"
    
    # Check specific error message
    assert_match(/empty or not properly loaded/, errors.join(' '), 
                "Should identify nil config")
  end

  def test_validate_bang_raises_error
    # Test that validate! raises an error on invalid config
    invalid_config = {}
    
    assert_raises(SchemaValidator::ConfigurationError) do
      SchemaValidator.validate!(invalid_config)
    end
  end
end