#!/usr/bin/env ruby
# This is a test for the configuration loading in chef_ci_status.rb

require 'minitest/autorun'
require 'yaml'
require 'tempfile'

# Set test mode to avoid strict validation in tests
ENV['CHEF_OSS_STATS_TEST_MODE'] = 'true'

# Add lib directory to load path
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

class ConfigLoadingTest < Minitest::Test
  def setup
    # Create a temporary config file
    @temp_config = Tempfile.new(['test_config', '.yml'])
    @temp_config.write(<<~YAML)
      default_org: 'test-org'
      default_repo: 'test-repo'
      default_branches:#{' '}
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
    # Using --dry-run to avoid actual GitHub API calls
    script_path = File.expand_path('../src/chef_ci_status.rb', __dir__)
    output = `ruby #{script_path} --config #{@temp_config.path} --dry-run 2>&1`

    # Verify the config was loaded
    assert_match(/Loaded custom configuration from/, output,
                'Custom config not loaded')
    refute_match(/Warning: Config file.*not found/, output,
                'Unexpected warning about config file not found')
    refute_match(/Error loading custom configuration/, output,
                'Error loading custom configuration')
  end

  def test_fallback_to_defaults
    # Test that the script falls back to defaults when config isn't found
    # We use a non-existent file path
    script_path = File.expand_path('../src/chef_ci_status.rb', __dir__)
    output = `ruby #{script_path} --config /nonexistent/path.yml --dry-run 2>&1`

    # Verify the output contains an error about the missing file
    assert_match(/Config file.*not found/, output,
                 'Missing error about non-existent config file')

    # Check default org is used
    assert_match(%r{\[DRY RUN\] Would analyze \[chef/chef\]}, output,
                 'Default org/repo not used as fallback')
  end

  def test_partial_configuration
    # Test handling of partial configuration (missing some keys)
    partial_config = Tempfile.new(['partial_config', '.yml'])
    partial_config.write(<<~YAML)
      # Only includes some of the required settings
      default_org: 'partial-org'
      default_repo: 'partial-repo'
      # Missing default_branches, default_days, default_mode
    YAML
    partial_config.close

    # We use --verbose to see the options hash directly
    # Add --dry-run to skip GitHub API calls
    script_path = File.expand_path('../src/chef_ci_status.rb', __dir__)
    opts = "--config #{partial_config.path} --verbose --dry-run"
    cmd = "ruby #{script_path} #{opts}"
    output = `#{cmd} 2>&1`

    # Test that config loaded successfully
    assert_match(/Loaded custom configuration from/, output,
               'Partial config not loaded')

    # Look for the options hash in the output
    assert_match(/Options:/, output, 'Options hash not found in output')

    # Check that our custom values were loaded
    assert_match(/:org=>"partial-org"/, output,
                'Custom org not loaded from partial config')
    assert_match(/:repo=>"partial-repo"/, output,
                'Custom repo not loaded from partial config')

    # Check defaults are used for unspecified values
    assert_match(/:days=>30/, output,
                'Default days not used for missing value')

    partial_config.unlink
  end

  def test_malformed_yaml_handling
    # Test error handling for malformed YAML
    malformed_config = Tempfile.new(['malformed_config', '.yml'])
    malformed_config.write(<<~YAML)
      default_org: 'test-org
      # Missing closing quote above - invalid YAML
      default_repo: test-repo
    YAML
    malformed_config.close

    script_path = File.expand_path('../src/chef_ci_status.rb', __dir__)
    cmd = "ruby #{script_path} --config #{malformed_config.path} --dry-run"
    output = `#{cmd} 2>&1`

    # Should report error loading malformed config
    assert_match(/Failed to load custom configuration/, output,
               'Missing error for malformed YAML')

    # Should mention YAML syntax
    assert_match(/syntax|parse/i, output,
               'Error should mention YAML syntax problem')

    # Should fall back to defaults
    assert_match(%r{\[DRY RUN\] Would analyze \[chef/chef\]}, output,
               'Not falling back to defaults with malformed config')

    malformed_config.unlink
  end

  def test_config_affects_script_behavior
    # Test that config affects script behavior (not just help text)
    # We'll create a minimal config and run a simple command

    minimal_config = Tempfile.new(['behavior_test', '.yml'])
    minimal_config.write(<<~YAML)
      default_org: 'behavior-org'
      default_repo: 'behavior-repo'
      default_days: 7
      default_mode: 'ci'
      default_branches:#{' '}
        - 'behavior-branch'
    YAML
    minimal_config.close

    # Using --verbose to see the options hash
    script_path = File.expand_path('../src/chef_ci_status.rb', __dir__)
    cmd = "ruby #{script_path} --config #{minimal_config.path} --verbose 2>&1"
    output = `#{cmd} || echo "Error execution returned non-zero"`

    # Verify the config was loaded successfully
    assert_match(/Loaded custom configuration from/, output,
               "Config file wasn't loaded")

    # Check for options hash
    assert_match(/Options:/, output, 'Options hash not found in output')

    # Check that values from the config file are used
    assert_match(/:org=>"behavior-org"/, output,
                'Configuration not affecting default_org')
    assert_match(/:repo=>"behavior-repo"/, output,
                'Configuration not affecting default_repo')
    assert_match(/:days=>7/, output,
                'Configuration not affecting default_days')
    assert_match(/:branches=>\["behavior-branch"\]/, output,
                'Configuration not affecting default_branches')

    minimal_config.unlink
  end

  def test_command_line_args_override_config
    # Test that command line arguments override configuration values
    override_config = Tempfile.new(['override_test', '.yml'])
    override_config.write(<<~YAML)
      default_org: 'config-org'
      default_repo: 'config-repo'
      default_days: 15
    YAML
    override_config.close

    # We'll pass command line args that override config values
    cmd = "ruby #{File.expand_path('../src/chef_ci_status.rb', __dir__)} " \
          "--config #{override_config.path} --org cli-org --repo cli-repo " \
          "--verbose 2>&1 || echo 'Error execution returned non-zero'"
    output = `#{cmd}`

    # Verify config was loaded
    assert_match(/Loaded custom configuration from/, output,
                "Config file wasn't loaded")

    # Check for options hash
    assert_match(/Options:/, output, 'Options hash not found in output')

    # Check CLI args override config values in options hash
    assert_match(/:org=>"cli-org"/, output,
                'CLI args not overriding config value for org')
    assert_match(/:repo=>"cli-repo"/, output,
                'CLI args not overriding config value for repo')

    # Verify config values are not being used
    refute_match(/:org=>"config-org"/, output,
                'Config values not being overridden by CLI args')

    override_config.unlink
  end

  def test_ci_timeout_option
    # Create a custom config file for testing
    custom_timeout_config = Tempfile.new(['custom_timeout', '.yml'])
    custom_timeout_config.write(<<~YAML)
      default_org: 'timeout-org'
      default_repo: 'timeout-repo'
      default_days: 10
      default_mode: 'all'
      ci_timeout: 120  # Custom timeout value different from default
    YAML
    custom_timeout_config.close

    begin
      # Run with verbose to see options
      output = `ruby #{File.expand_path('../src/chef_ci_status.rb',
__dir__)} --config #{custom_timeout_config.path} --verbose --dry-run 2>&1`

      # Check that the custom CI timeout was loaded from the config file
      assert_match(/Options: {.*:ci_timeout=>120.*}/, output,
                 'Custom CI timeout not loaded from config')
    ensure
      custom_timeout_config.unlink
    end

    # Test CLI option overrides config
    output_cli = `ruby #{File.expand_path('../src/chef_ci_status.rb',
__dir__)} --ci-timeout 60 --verbose --dry-run 2>&1`

    # CLI should override config
    assert_match(/Options: {.*:ci_timeout=>60.*}/, output_cli,
                'CLI --ci-timeout not overriding config value')
  end

  def test_skip_ci_option
    # Test the --skip-ci option
    output = `ruby #{File.expand_path('../src/chef_ci_status.rb',
__dir__)} --skip-ci --verbose --dry-run 2>&1`

    # Check that CI mode is not in the modes array
    refute_match(/:mode=>\["ci"/, output,
                '--skip-ci not removing ci from modes')
    refute_match(/:mode=>\["all"/, output,
                '--skip-ci not processing all mode correctly')

    # Should still include pr and issue
    assert_match(/:mode=>\["pr", "issue"\]/, output,
                'PR and Issue modes not included with --skip-ci')
  end

  def test_dry_run_option
    # Test the --dry-run option
    output = `ruby #{File.expand_path('../src/chef_ci_status.rb',
__dir__)} --dry-run --verbose 2>&1`

    # Check that dry run is set
    assert_match(/Options: {.*:dry_run=>true.*}/, output,
                '--dry-run not setting dry_run option')

    # Should show dry run message
    assert_match(/\[DRY RUN\] Would analyze/, output,
                'Dry run message not displayed')
  end

  def test_config_merging_behavior
    # Test that the config system properly merges configuration
    # Priority: CLI args > --config file > Settings > hardcoded defaults

    # Create a config file with custom settings
    merge_config = Tempfile.new(['merge_test', '.yml'])
    merge_config.write(<<~YAML)
      default_org: 'merge-org'
      default_repo: 'merge-repo'
      default_days: 25
      default_branches:
        - 'merge-branch'
      default_mode: 'pr'
      ci_timeout: 90  # Custom CI timeout
    YAML
    merge_config.close

    # Create settings.local.yml for the Config gem to load
    local_config_path = File.expand_path('../config/settings.local.yml',
__dir__)
    local_config_existed = File.exist?(local_config_path)
    local_config_content = nil

    if local_config_existed
      # Save existing content to restore later
      local_config_content = File.read(local_config_path)
    end

    # Write test content to settings.local.yml
    File.write(local_config_path, <<~YAML)
      default_org: "local-org"
      default_mode: "issue"
    YAML

    begin
      # Test with CLI args to override day value
      cli_output = `ruby #{File.expand_path('../src/chef_ci_status.rb',
__dir__)} --config #{merge_config.path} --days 3 --verbose --dry-run 2>&1`

      # Verify config was loaded
      assert_match(/Loaded custom configuration from/, cli_output,
                "Config file wasn't loaded")

      # Check for options hash
      assert_match(/Options:/, cli_output, 'Options hash not found in output')

      # Check CLI args override config value for days
      assert_match(/:days=>3/, cli_output,
                'CLI args not overriding config days')

      # Check that --config file values are used (not from settings.local.yml)
      assert_match(/:org=>"merge-org"/, cli_output,
                'Config file value not being used for org')

      # In a real application, you'd test the entire priority chain, but
      # this is enough to verify our configuration structure works
    ensure
      # Clean up: restore or remove settings.local.yml
      if local_config_existed && local_config_content
        File.write(local_config_path, local_config_content)
      elsif File.exist?(local_config_path)
        File.unlink(local_config_path)
      end
    end

    merge_config.unlink
  end
end
