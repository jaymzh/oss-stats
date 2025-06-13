require 'rspec'
require_relative '../src/ci_stats' # This will load ci_stats_config as well
require_relative '../src/lib/oss_stats/ci_stats_config'

# Helper module to reset CiStatsConfig to its default state
module OssStats
  module CiStatsConfig
    def self.reset_defaults!
      # Reset all configuration attributes to their default values as defined in ci_stats_config.rb
      # or to a known clean state.
      @config_file = nil # Used by parse_options to check if a file was loaded via --config
      @config = nil      # Explicitly set by --config option in parse_options

      # Defaults from Mixlib::Config
      self.default_branches = ['main']
      self.default_days = 30
      self.log_level = :info
      self.ci_timeout = 600
      self.github_api_endpoint = nil # Default is nil in the file
      self.github_token = nil
      self.limit_gh_ops_per_minute = nil
      self.include_list = false
      self.organizations = {}
      self.mode = ['all']
      # Add any other attributes that might be dynamically set or need clearing
    end
  end
end

RSpec.describe 'ci_stats command-line options and configuration' do
  # Make the methods from ci_stats.rb available in the tests
  # This assumes ci_stats.rb defines methods at the top level or in a module
  # If parse_options is a method within a class/module, adjust accordingly.
  # For this test, we need to be able to call `parse_options`
  # Let's include the Main module if parse_options is there, or figure out how it's called.
  # Assuming parse_options is a top-level method made available by requiring ../src/ci_stats
  # If not, this might need adjustment. For now, assume it's globally available or callable.

  before(:each) do
    OssStats::CiStatsConfig.reset_defaults!
    ARGV.clear # Clear command line arguments before each test
    # Stub logger interactions to avoid noise and irrelevant checks
    allow(OssStats::CiStatsConfig.log).to receive(:level=)
    # Stub exit to prevent tests from terminating prematurely
    allow_any_instance_of(Object).to receive(:exit).and_raise(SystemExit, "SystemExit called")

    # Prevent actual file loading attempts unless specifically testing that feature
    allow(OssStats::CiStatsConfig).to receive(:config_file).and_return(nil)
    allow(File).to receive(:exist?).and_call_original # Allow specific mocks later
  end

  describe '#parse_options' do
    # It seems parse_options is defined in a way that it's not directly callable as a global method.
    # Let's assume it's part of the Main module, or we might need to load the script in a specific way.
    # For now, I will try to call it as if it's available.
    # If this fails, I'll need to adjust how `parse_options` is invoked.
    # It's defined in bin/ci_stats, not src/ci_stats.rb. This means I need to load that file.
    # However, RSpec best practices usually involve testing library code (src) not executables (bin).
    # Let's assume the core option parsing logic can be extracted or is available.
    # The provided file structure points to `src/ci_stats.rb` which contains `parse_options`.

    it 'sets default values when no options are given' do
      # ARGV is already cleared in before(:each)
      # Need to ensure parse_options is callable.
      # It seems parse_options is a top-level method in ci_stats.rb
      # If ci_stats.rb is structured like:
      # module Main; def parse_options; end; end; include Main
      # or just def parse_options at top level.
      # Let's assume it's made available by `require_relative '../src/ci_stats'`

      # Call parse_options - this might need adjustment based on how it's defined in src/ci_stats.rb
      # For now, assuming it's a method that can be called directly or on a module.
      # Let's simulate the behavior of the executable if parse_options is hard to call directly.
      # The task description implies parse_options is a callable function/method.
      # It is indeed defined in src/ci_stats.rb.

      parse_options(ARGV) # Pass ARGV explicitly

      expect(OssStats::CiStatsConfig.default_days).to eq(30)
      expect(OssStats::CiStatsConfig.default_branches).to eq(['main'])
      expect(OssStats::CiStatsConfig.log_level).to eq(:info) # Default from Mixlib
      expect(OssStats::CiStatsConfig.mode).to eq(['all'])
      expect(OssStats::CiStatsConfig.include_list).to be false
      expect(OssStats::CiStatsConfig.limit_gh_ops_per_minute).to be_nil
      expect(OssStats::CiStatsConfig.organizations).to eq({})
      expect(OssStats::CiStatsConfig.github_api_endpoint).to be_nil
      expect(OssStats::CiStatsConfig.ci_timeout).to eq(600)
    end

    it 'parses --days option' do
      ARGV.concat(['--days', '15'])
      parse_options(ARGV)
      expect(OssStats::CiStatsConfig.default_days).to eq(15)
    end

    it 'parses --branches option' do
      ARGV.concat(['--branches', 'dev,test'])
      parse_options(ARGV)
      expect(OssStats::CiStatsConfig.default_branches).to eq(['dev', 'test'])
    end

    it 'parses --log-level option' do
      ARGV.concat(['--log-level', 'debug'])
      parse_options(ARGV)
      expect(OssStats::CiStatsConfig.log_level).to eq(:debug)
    end

    it 'parses --mode option' do
      ARGV.concat(['--mode', 'ci,issue'])
      parse_options(ARGV)
      expect(OssStats::CiStatsConfig.mode).to eq(['ci', 'issue'])
    end

    it 'parses --limit-gh-ops option' do
      ARGV.concat(['--limit-gh-ops', '100'])
      parse_options(ARGV)
      expect(OssStats::CiStatsConfig.limit_gh_ops_per_minute).to eq(100)
    end

    it 'parses --include-list option' do
      ARGV.concat(['--include-list'])
      parse_options(ARGV)
      expect(OssStats::CiStatsConfig.include_list).to be true
    end

    it 'parses --org and --repo options' do
      ARGV.concat(['--org', 'myorg', '--repo', 'myrepo'])
      parse_options(ARGV)
      expected_orgs = {
        'myorg' => {
          'repositories' => {
            'myrepo' => {} # Default empty hash for repo settings
          }
        }
      }
      expect(OssStats::CiStatsConfig.organizations).to eq(expected_orgs)
    end

    context 'with invalid options' do
      it 'raises OptionParser::InvalidArgument for invalid --mode' do
        ARGV.concat(['--mode', 'invalid'])
        # The OptionParser itself should raise this before our custom checks.
        # parse_options uses a `rescue OptionParser::InvalidArgument` block which calls exit.
        # So we expect SystemExit.
        expect { parse_options(ARGV) }.to raise_error(SystemExit)
      end

      it 'exits if --org is given without --repo' do
        ARGV.concat(['--org', 'myorg'])
        expect { parse_options(ARGV) }.to raise_error(SystemExit)
      end

      it 'exits if --repo is given without --org' do
        ARGV.concat(['--repo', 'myrepo'])
        expect { parse_options(ARGV) }.to raise_error(SystemExit)
      end
    end

    context 'config file loading' do
      let(:dummy_config_path) { '/tmp/dummy_config.rb' } # Using /tmp to avoid local clutter

      it 'loads config file specified with --config' do
        ARGV.concat(['--config', dummy_config_path])
        allow(File).to receive(:exist?).with(dummy_config_path).and_return(true)
        # parse_options calls expand_path internally for the --config option.
        allow(File).to receive(:expand_path).with(dummy_config_path).and_return(dummy_config_path)

        # Expect from_file to be called on the CiStatsConfig module
        expect(OssStats::CiStatsConfig).to receive(:from_file).with(dummy_config_path)

        # Need to handle the potential SystemExit if --org/--repo are not also provided or in the config
        # For this test, we only care about from_file being called.
        # We can provide dummy org/repo to satisfy the parser's later checks.
        OssStats::CiStatsConfig.organizations = {'dummy' => {'repositories' => {'dummyrepo' => {}}}}

        parse_options(ARGV)
      end

      it 'attempts to load default config file if no --config is given' do
        default_config_location = File.join(ENV['HOME'], '.config', 'oss_stats', 'ci_stats_config.rb')
        # Undo the global stub for config_file for this test
        allow(OssStats::CiStatsConfig).to receive(:config_file).and_call_original

        # Mock specific file existence checks
        allow(File).to receive(:exist?).with(default_config_location).and_return(true)
        # Prevent other default locations from being found first
        allow(File).to receive(:exist?).with(File.join(Dir.pwd, 'ci_stats_config.rb')).and_return(false)
        allow(File).to receive(:exist?).with('/etc/ci_stats_config.rb').and_return(false)


        expect(OssStats::CiStatsConfig).to receive(:from_file).with(default_config_location)

        # Provide dummy org/repo to satisfy parser checks if config doesn't provide them
        OssStats::CiStatsConfig.organizations = {'dummy' => {'repositories' => {'dummyrepo' => {}}}}

        parse_options(ARGV) # ARGV is empty
      end

      it 'CLI options override options loaded from a config file' do
        ARGV.concat(['--config', dummy_config_path, '--days', '20'])
        allow(File).to receive(:exist?).with(dummy_config_path).and_return(true)
        allow(File).to receive(:expand_path).with(dummy_config_path).and_return(dummy_config_path)

        # Mock the effect of from_file: it sets default_days to 10
        allow(OssStats::CiStatsConfig).to receive(:from_file).with(dummy_config_path) do
          OssStats::CiStatsConfig.default_days = 10
          # Also ensure organizations are set to prevent exit
          OssStats::CiStatsConfig.organizations = {'dummyorg' => {'repositories' => {'dummyrepo' => {}}}}
        end

        parse_options(ARGV)
        expect(OssStats::CiStatsConfig.default_days).to eq(20) # CLI option (20) should override file option (10)
      end

      it 'CLI --org and --repo options override organizations from config file' do
        # Setup initial organizations as if loaded from a file
        initial_orgs = {
          'org1' => { 'repositories' => { 'repo1a' => {}, 'repo1b' => {} } },
          'org2' => { 'repositories' => { 'repo2a' => {} } }
        }
        OssStats::CiStatsConfig.organizations = initial_orgs

        ARGV.concat(['--org', 'org_cli', '--repo', 'repo_cli'])
        parse_options(ARGV)

        expected_orgs = {
          'org_cli' => {
            'repositories' => {
              'repo_cli' => {}
            }
          }
        }
        expect(OssStats::CiStatsConfig.organizations).to eq(expected_orgs)
      end
    end
  end

  describe 'get_effective_settings (via main repos_to_process)' do
    let(:sample_org_config) do
      {
        'org1' => {
          'default_days' => 10,
          'default_branches' => ['main_org1'],
          'repositories' => {
            'repo1a' => { 'days' => 5, 'branches' => ['main_repo1a'] },
            'repo1b' => {} # Inherits from org1
          }
        },
        'org2' => {
          'repositories' => {
            'repo2a' => { 'branches' => ['feature_branch'] }, # Inherits global days
            'repo2b' => {}  # Inherits global days and branches
          }
        }
      }
    end

    before(:each) do
      # Reset config and ARGV is handled by the top-level before(:each)
      OssStats::CiStatsConfig.default_days = 30
      OssStats::CiStatsConfig.default_branches = ['default_global']
      OssStats::CiStatsConfig.organizations = sample_org_config
      OssStats::CiStatsConfig.mode = ['all'] # Needs a valid mode

      # Stub methods called in main after repos_to_process is built
      allow(self).to receive(:get_github_token!).and_return('fake_token')
      allow(Octokit::Client).to receive(:new).and_return(instance_double(Octokit::Client)) # Return a dummy client

      # Stub the actual processing methods
      allow(self).to receive(:get_pr_and_issue_stats)
      allow(self).to receive(:print_pr_or_issue_stats)
      allow(self).to receive(:get_failed_tests_from_ci)
      allow(self).to receive(:print_failed_tests_results)
      allow(self).to receive(:print_overall_summary)
      allow(self).to receive(:handle_include_list)

      # Stub sleep to prevent delays if rate limiting is hit
      allow(self).to receive(:sleep) # Covers rate_limited_sleep if it calls sleep
      allow(self).to receive(:rate_limited_sleep) # Stub directly just in case
    end

    it 'correctly resolves settings for each repository' do
      # Need to call main and somehow capture repos_to_process.
      # This is tricky as repos_to_process is a local variable in main.
      # Option 1: Replicate the logic that builds repos_to_process here.
      # Option 2: Modify main to store repos_to_process in a testable place (e.g., a class variable for testing).
      # Option 3: Use a spy/mock to capture arguments to a method called for each repo.

      # Let's try Option 1: Replicate the logic from main
      # This avoids modifying the source code for testability but means duplication.

      # The logic in main is approximately:
      # global_settings = { days: OssStats::CiStatsConfig.default_days, branches: OssStats::CiStatsConfig.default_branches, ... }
      # get_effective_settings = ->(org_name, repo_name) { ... }
      # OssStats::CiStatsConfig.organizations.each do |org_name, org_config|
      #   org_config['repositories'].each do |repo_name, repo_config|
      #     repos_to_process << get_effective_settings.call(org_name, repo_name)
      #   end
      # end
      # So, we need to define `get_effective_settings` lambda as it is in `main`.
      # This lambda is defined inside `main`. It's not trivial to test it directly without refactoring `main`.

      # Given the constraints, let's test by checking the arguments passed to a processing method.
      # We can check what `get_pr_and_issue_stats` (or another method) is called with for each repo.
      # This indirectly tests `get_effective_settings`.

      expected_calls = [
        a_hash_including(org: 'org1', repo: 'repo1a', days: 5, branches: ['main_repo1a']),
        a_hash_including(org: 'org1', repo: 'repo1b', days: 10, branches: ['main_org1']),
        a_hash_including(org: 'org2', repo: 'repo2a', days: 30, branches: ['feature_branch']),
        a_hash_including(org: 'org2', repo: 'repo2b', days: 30, branches: ['default_global'])
      ]

      # We need to ensure the methods are called in a specific order or capture all calls.
      # Using `ordered` is strict. Let's capture all calls to one of the processing methods.
      # `get_pr_and_issue_stats` is called if 'pr' or 'issue' mode is active.
      # `get_failed_tests_from_ci` is called if 'ci' mode is active.
      # Since mode is ['all'], both will be called for each repo.

      # We will check the options passed to `get_pr_and_issue_stats`
      # (or `get_failed_tests_from_ci` - assuming structure is similar)

      # Allow the method to be called and store its arguments
      received_options_for_pr_stats = []
      allow(self).to receive(:get_pr_and_issue_stats) do |client, opts|
        received_options_for_pr_stats << opts
        # Return dummy data to allow main to proceed
        { pr: {}, issue: {} }
      end

      # Call main - parse_options should have been called by now if ARGV was set.
      # However, main itself calls parse_options.
      # For this test, we've set up CiStatsConfig directly.
      # We should call main without ARGV so it uses the pre-set config.
      ARGV.clear # Ensure no CLI options interfere

      # Stubbing parse_options itself to prevent it from re-parsing ARGV or loading files
      allow(self).to receive(:parse_options)


      begin
        main
      rescue SystemExit
        # Expected if exit is called, e.g. by a check after parsing if no orgs were found.
        # Our setup ensures orgs are present.
      end

      # Verify that each expected call was made, irrespective of order for this test.
      expected_calls.each do |expected_option_set|
        expect(received_options_for_pr_stats).to include(expected_option_set)
      end
      expect(received_options_for_pr_stats.size).to eq(expected_calls.size)
    end
  end
end
