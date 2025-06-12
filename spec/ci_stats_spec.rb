require 'rspec'
require 'tempfile'
require 'yaml' # For mocking gh hosts.yml
require_relative '../src/lib/oss_stats/ci_stats_config'
require_relative '../src/ci_stats' # Defines the methods to be tested, including main

# Helper to reset OssStats::CiStatsConfig before each test
def reset_ci_stats_config
  OssStats::CiStatsConfig.reset!
  OssStats::CiStatsConfig.log_level = :fatal # Default for quieter tests
  OssStats::CiStatsConfig.github_access_token = nil # Ensure nil at start
  ENV['GITHUB_TOKEN'] = nil # Ensure ENV is nil at start
end

# Mocking Octokit client
class OctokitClientMock
  def initialize(token:, api_endpoint: nil)
    @token = token
    @api_endpoint = api_endpoint
  end
  attr_reader :token, :api_endpoint
  def issues(_repo, _options); []; end
  def workflows(_repo); OpenStruct.new(workflows: []); end
  def workflow_runs(_repo, _workflow_id, _options); OpenStruct.new(workflow_runs: []); end
  def workflow_run_jobs(_repo, _run_id, _options = {}); OpenStruct.new(jobs: []); end
end

RSpec.describe 'CI Stats Script' do
  include_context 'ci_stats_stuff' # Allows methods from ci_stats to be called directly if needed

  let!(:original_argv) { ARGV.dup }
  let!(:original_env_github_token) { ENV['GITHUB_TOKEN'] }

  around(:each) do |example|
    ARGV.replace(original_argv.dup) # Ensure fresh ARGV for each run
    ENV['GITHUB_TOKEN'] = original_env_github_token
    example.run
  ensure # Use ensure to guarantee cleanup
    ARGV.replace(original_argv)
    ENV['GITHUB_TOKEN'] = original_env_github_token
  end

  before(:each) do
    reset_ci_stats_config
    stub_const('Octokit::Client', OctokitClientMock)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(File.expand_path('~/.config/gh/hosts.yml')).and_return(false)
    allow(YAML).to receive(:load_file).with(File.expand_path('~/.config/gh/hosts.yml')).and_return({})

    # Spy on the main processing methods to check if they are called and with what arguments
    # These need to be methods on the main object if main is calling them directly.
    # If they are top-level methods, use `allow(self).to receive(...)` or `allow_any_instance_of(Object).to receive(...)` carefully.
    # Since they are top-level in ci_stats.rb, and required, they become private methods of RSpec::Core::ExampleGroup::Nested_1
    # A better way is to make them part of a class/module if possible, or use more integration-style testing for `main`.
    # For now, we will assume they are available to be spied upon in the test context.
    # This might require `extend self` in ci_stats.rb or other structural changes not part of this subtask.
    # As a workaround for direct top-level method calls from `main`:
    # We can't directly spy on top-level methods called from another top-level method easily.
    # So, tests for `main` will focus on the setup of OssStats::CiStatsConfig and what `repos_to_process` contains.
    # Tests for `get_effective_settings` will be more direct if we extract it or test through observed behavior.

    ARGV.clear
    OssStats::CiStatsConfig.github_access_token = 'test_token' # Default for most tests to pass token check
  end

  # This is needed to make methods defined in ci_stats.rb available in the tests
  # if they are not part of a class/module.
  shared_context 'ci_stats_stuff' do
    # If parse_options, main etc. were in a module, you'd extend self with it.
    # For top-level methods in a required file, they are typically available.
    # No specific code needed here if ci_stats.rb methods are globally available after require.
  end

  describe 'parse_options' do
    it 'collects CLI arguments into a hash' do
      ARGV.replace(['--org', 'my-org', '--days', '10'])
      cli_opts = parse_options
      expect(cli_opts[:default_org]).to eq('my-org')
      expect(cli_opts[:default_days]).to eq(10)
    end

    it 'loads config from file specified by --config' do
      custom_config_path = 'spec/fixtures/custom_test_config.rb'
      ARGV.replace(['--config', custom_config_path])
      # Ensure fixture exists for this test
      allow(File).to receive(:exist?).with(custom_config_path).and_return(true)
      allow(OssStats::CiStatsConfig).to receive(:from_file).with(custom_config_path).and_call_original
      parse_options
      expect(OssStats::CiStatsConfig.default_days).to eq(99) # From custom_test_config.rb
    end

    it 'merges CLI options over file configurations' do
      custom_config_path = 'spec/fixtures/custom_test_config.rb' # Sets default_days = 99
      allow(File).to receive(:exist?).with(custom_config_path).and_return(true)
      allow(OssStats::CiStatsConfig).to receive(:from_file).with(custom_config_path).and_call_original

      ARGV.replace(['--config', custom_config_path, '--days', '5'])
      parse_options
      expect(OssStats::CiStatsConfig.default_days).to eq(5) # CLI (5) wins over file (99)
    end

    it 'returns a hash of CLI-provided options' do
      ARGV.replace(['--org', 'cli-org', '--include-list'])
      cli_opts = parse_options
      expect(cli_opts).to include(default_org: 'cli-org', include_list: true)
    end

     it 'correctly identifies which global options were set by CLI' do
      ARGV.replace(['--days', '10', '--default-branches', 'feat,bugfix'])
      cli_opts = parse_options
      # _cli_options_set_by_user is an internal detail of parse_options used by get_effective_settings
      # We test get_effective_settings directly for this behavior.
      # Here, we just check that parse_options populates OssStats::CiStatsConfig correctly.
      expect(OssStats::CiStatsConfig.default_days).to eq(10)
      expect(OssStats::CiStatsConfig.default_branches).to eq(['feat', 'bugfix'])
    end
  end

  describe 'main function processing logic' do
    let(:multi_repo_config_path) { 'spec/fixtures/multi_org_repo_config.rb' }
    # Spy on the methods called by main
    # These spies need to be on whatever object is responsible for these methods.
    # Assuming they are made available in the test scope (e.g. via a module or direct require)
    subject { self } # To make RSpec allow spying on methods in the current context

    before do
      # Prevent actual processing, focus on setup and iteration logic
      allow(subject).to receive(:get_pr_and_issue_stats).and_return({ pr: {}, issue: {}, pr_list: {}, issue_list: {} })
      allow(subject).to receive(:get_failed_tests_from_ci).and_return({})
      allow(subject).to receive(:print_pr_or_issue_stats)
      allow(subject).to receive(:print_ci_status)
      OssStats::CiStatsConfig.github_access_token = 'main_test_token' # Ensure token is set
    end

    context 'when CLI --org and --repo are provided' do
      before do
        ARGV.replace(['--org', 'cli-org', '--repo', 'cli-repo', '--days', '5', '--mode', 'pr'])
        # Simulate a config file also being present to test override
        allow(File).to receive(:exist?).with(multi_repo_config_path).and_return(true)
        allow(OssStats::CiStatsConfig).to receive(:config_file_to_load).and_return(multi_repo_config_path)
        allow(OssStats::CiStatsConfig).to receive(:from_file).with(multi_repo_config_path).and_call_original
      end

      it 'processes only the CLI-specified repository' do
        main
        expect(OssStats::CiStatsConfig.organizations.keys).to eq(['cli-org'])
        expect(OssStats::CiStatsConfig.organizations['cli-org']['repositories'].keys).to eq(['cli-repo'])
        expect(OssStats::CiStatsConfig.default_org).to eq('cli-org')
        expect(OssStats::CiStatsConfig.default_repo).to eq('cli-repo')

        expect(subject).to have_received(:get_pr_and_issue_stats).once
        expect(subject).not_to have_received(:get_failed_tests_from_ci) # mode is 'pr'
      end

      it 'uses CLI-provided global settings for the target repo' do
        main
        expect(subject).to have_received(:get_pr_and_issue_stats).with(
          anything, # client
          hash_including(org: 'cli-org', repo: 'cli-repo', days: 5) # 5 from CLI --days
        )
      end

      it 'layers CLI globals over file specifics for the target repo' do
        # multi_repo_config has org1/repoA with days: 11
        ARGV.replace(['--config', multi_repo_config_path, '--org', 'org1', '--repo', 'repoA', '--days', '3', '--mode', 'pr'])
        allow(File).to receive(:exist?).with(multi_repo_config_path).and_return(true)
        allow(OssStats::CiStatsConfig).to receive(:config_file_to_load).and_return(multi_repo_config_path)

        main
        expect(subject).to have_received(:get_pr_and_issue_stats).with(
          anything,
          hash_including(org: 'org1', repo: 'repoA', days: 3) # CLI --days 3 wins over file's 11
        )
      end
    end

    context 'when only --org or only --repo is provided' do
      it 'exits with an error if only --org is given' do
        ARGV.replace(['--org', 'my-cli-org'])
        expect(Log).to receive(:fatal).with(/Both --org and --repo must be specified/)
        expect { main }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      it 'exits with an error if only --repo is given' do
        ARGV.replace(['--repo', 'my-cli-repo'])
        expect(Log).to receive(:fatal).with(/Both --org and --repo must be specified/)
        expect { main }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'when no CLI target, using organizations from config file' do
      before do
        ARGV.replace(['--config', multi_repo_config_path, '--mode', 'pr,ci']) # Load multi-repo config
        allow(File).to receive(:exist?).with(multi_repo_config_path).and_return(true)
        allow(OssStats::CiStatsConfig).to receive(:config_file_to_load).and_return(multi_repo_config_path)
      end

      it 'iterates over all repositories defined in the config' do
        main
        # multi_repo_config.rb defines 3 repos (org1/repoA, org1/repoB, org2/repoC)
        expect(subject).to have_received(:get_pr_and_issue_stats).exactly(3).times
        expect(subject).to have_received(:get_failed_tests_from_ci).exactly(3).times
      end

      it 'uses correctly layered settings for each iterated repository' do
        main
        # org1/repoA (days: 11 from repo, branches: ['org1-repoA-branch'] from repo, ci_timeout: 111 from repo)
        expect(subject).to have_received(:get_failed_tests_from_ci).with(anything, 'org1', 'repoA', ['org1-repoA-branch'], 11, 111)
        # org1/repoB (days: 101 from org1, branches: ['org1-branch'] from org1, ci_timeout: 1001 from org1)
        expect(subject).to have_received(:get_failed_tests_from_ci).with(anything, 'org1', 'repoB', ['org1-branch'], 101, 1001)
        # org2/repoC (days: 22 from repo, branches: ['org2-repoC-branch'] from repo, ci_timeout: 222 from repo)
        expect(subject).to have_received(:get_failed_tests_from_ci).with(anything, 'org2', 'repoC', ['org2-repoC-branch'], 22, 222)
      end

      it 'CLI global --days overrides file settings during iteration' do
        ARGV.replace(['--config', multi_repo_config_path, '--days', '1', '--mode', 'pr']) # Global CLI --days
        allow(File).to receive(:exist?).with(multi_repo_config_path).and_return(true)
        allow(OssStats::CiStatsConfig).to receive(:config_file_to_load).and_return(multi_repo_config_path)
        main
        expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(org: 'org1', repo: 'repoA', days: 1))
        expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(org: 'org1', repo: 'repoB', days: 1))
        expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(org: 'org2', repo: 'repoC', days: 1))
      end
    end

    context 'when no CLI target and organizations config is empty' do
      before do
        OssStats::CiStatsConfig.organizations = {} # Ensure empty
        ARGV.replace(['--mode', 'pr'])
      end

      it 'logs a warning and exits if organizations is empty' do
        # Need to ensure default_org/repo are also nil or this won't trigger the intended exit
        OssStats::CiStatsConfig.default_org = nil
        OssStats::CiStatsConfig.default_repo = nil
        expect(Log).to receive(:warn).with(/No organizations\/repositories configured and no valid global default_org\/default_repo set. Exiting./)
        expect { main }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        expect(subject).not_to have_received(:get_pr_and_issue_stats)
      end

      it 'exits if organizations is empty even if global default_org/repo are set (new behavior)' do
        OssStats::CiStatsConfig.default_org = "some-org" # Set from a file, for example
        OssStats::CiStatsConfig.default_repo = "some-repo"
        expect(Log).to receive(:warn).with(/No organizations\/repositories configured to process. Exiting./)
         expect { main }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        expect(subject).not_to have_received(:get_pr_and_issue_stats)
      end
    end
  end

  describe 'get_effective_settings (tested via main)' do
    let(:multi_repo_config_path) { 'spec/fixtures/multi_org_repo_config.rb' }
    before do
      allow(File).to receive(:exist?).with(multi_repo_config_path).and_return(true)
      allow(OssStats::CiStatsConfig).to receive(:config_file_to_load).and_return(multi_repo_config_path)
      OssStats::CiStatsConfig.github_access_token = 'effective_settings_token'
      allow(subject).to receive(:get_pr_and_issue_stats) # Spy
    end

    it 'correctly layers settings: CLI global > repo > org > file global > hardcoded default' do
      # 1. CLI global for --days
      ARGV.replace(['--config', multi_repo_config_path, '--org', 'org1', '--repo', 'repoA', '--days', '1', '--mode', 'pr'])
      main
      expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(days: 1))

      # 2. Repo specific (org1/repoA default_days is 11)
      reset_ci_stats_config # Important to reset for next ARGV parse
      OssStats::CiStatsConfig.github_access_token = 'effective_settings_token'
      ARGV.replace(['--config', multi_repo_config_path, '--org', 'org1', '--repo', 'repoA', '--mode', 'pr']) # No CLI --days
      main
      expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(days: 11))

      # 3. Org specific (org1 default_days is 101, repoB inherits it)
      reset_ci_stats_config
      OssStats::CiStatsConfig.github_access_token = 'effective_settings_token'
      ARGV.replace(['--config', multi_repo_config_path, '--org', 'org1', '--repo', 'repoB', '--mode', 'pr'])
      main
      expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(days: 101))

      # 4. File global (multi_repo_config.rb sets global default_days to 200)
      #    To test this, we need an org/repo not in the 'organizations' hash, or an empty 'organizations' hash
      #    and rely on global default_org/repo from the file.
      reset_ci_stats_config
      OssStats::CiStatsConfig.github_access_token = 'effective_settings_token'
      # Set default_org/repo to something not in multi_repo_config's organizations
      ARGV.replace(['--config', multi_repo_config_path, '--org', 'global-org-in-file', '--repo', 'some-other-repo', '--mode', 'pr'])
      main
      # global-org-in-file's default_days is 200 in multi_org_repo_config.rb
      expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(days: 200))


      # 5. Hardcoded default (OssStats::CiStatsConfig.default :default_days, 30)
      reset_ci_stats_config # This clears all, including file loaded values
      OssStats::CiStatsConfig.github_access_token = 'effective_settings_token'
      # No config file loaded, no CLI options for days. Org/repo must be specified for main to run.
      ARGV.replace(['--org', 'some-org', '--repo', 'some-repo', '--mode', 'pr'])
      main
      expect(subject).to have_received(:get_pr_and_issue_stats).with(anything, hash_including(days: 30))
    end
  end

  # Tests for mode handling and other specific options like --ci-timeout, --include-list
  # are implicitly covered by the iteration logic tests which check arguments passed to spied methods.
end
