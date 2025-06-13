require 'rspec'
require_relative '../src/ci_stats' # This will load ci_stats_config as well
require_relative '../src/lib/oss_stats/ci_stats_config'

# Helper module to reset CiStatsConfig to its default state
module OssStats
  module CiStatsConfig
    def self.reset_defaults!
      # Reset all configuration attributes to their default values as defined
      # in ci_stats_config.rb or to a known clean state.
      @config_file = nil # Used by parse_options
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
    end
  end
end

RSpec.describe 'ci_stats command-line options and configuration' do
  before(:each) do
    OssStats::CiStatsConfig.reset_defaults!
    ARGV.clear # Clear command line arguments before each test
    allow(OssStats::CiStatsConfig.log).to receive(:level=)
    allow_any_instance_of(Object)
      .to receive(:exit)
      .and_raise(SystemExit, "SystemExit called")

    # Prevent actual file loading attempts unless specifically testing that
    allow(OssStats::CiStatsConfig).to receive(:config_file).and_return(nil)
    allow(File).to receive(:exist?).and_call_original
  end

  describe '#parse_options' do
    it 'sets default values when no options are given' do
      parse_options # ARGV is used implicitly

      expect(OssStats::CiStatsConfig.default_days).to eq(30)
      expect(OssStats::CiStatsConfig.default_branches).to eq(['main'])
      expect(OssStats::CiStatsConfig.log_level).to eq(:info)
      expect(OssStats::CiStatsConfig.mode).to eq(['all'])
      expect(OssStats::CiStatsConfig.include_list).to be false
      expect(OssStats::CiStatsConfig.limit_gh_ops_per_minute).to be_nil
      expect(OssStats::CiStatsConfig.organizations).to eq({})
      expect(OssStats::CiStatsConfig.github_api_endpoint).to be_nil
      expect(OssStats::CiStatsConfig.ci_timeout).to eq(600)
    end

    it 'parses --days option' do
      ARGV.concat(['--days', '15'])
      parse_options
      expect(OssStats::CiStatsConfig.default_days).to eq(15)
    end

    it 'parses --branches option' do
      ARGV.concat(['--branches', 'dev,test'])
      parse_options
      expect(OssStats::CiStatsConfig.default_branches).to eq(['dev', 'test'])
    end

    it 'parses --log-level option' do
      ARGV.concat(['--log-level', 'debug'])
      parse_options
      expect(OssStats::CiStatsConfig.log_level).to eq(:debug)
    end

    it 'parses --mode option' do
      ARGV.concat(['--mode', 'ci,issue'])
      parse_options
      expect(OssStats::CiStatsConfig.mode).to eq(['ci', 'issue'])
    end

    it 'parses --limit-gh-ops option' do
      ARGV.concat(['--limit-gh-ops', '100'])
      parse_options
      expect(OssStats::CiStatsConfig.limit_gh_ops_per_minute).to eq(100)
    end

    it 'parses --include-list option' do
      ARGV.concat(['--include-list'])
      parse_options
      expect(OssStats::CiStatsConfig.include_list).to be true
    end

    it 'parses --org and --repo options' do
      ARGV.concat(['--org', 'myorg', '--repo', 'myrepo'])
      parse_options
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
      it 'raises SystemExit for invalid --mode' do
        ARGV.concat(['--mode', 'invalid'])
        expect { parse_options }.to raise_error(SystemExit)
      end

      it 'exits if --org is given without --repo' do
        ARGV.concat(['--org', 'myorg'])
        expect { parse_options }.to raise_error(SystemExit)
      end

      it 'exits if --repo is given without --org' do
        ARGV.concat(['--repo', 'myrepo'])
        expect { parse_options }.to raise_error(SystemExit)
      end
    end

    context 'config file loading' do
      let(:dummy_config_path) { '/tmp/dummy_config.rb' }

      it 'loads config file specified with --config' do
        ARGV.concat(['--config', dummy_config_path])
        allow(File).to receive(:exist?).with(dummy_config_path).and_return(true)
        allow(File)
          .to receive(:expand_path)
          .with(dummy_config_path)
          .and_return(dummy_config_path)

        expect(OssStats::CiStatsConfig)
          .to receive(:from_file)
          .with(dummy_config_path)

        # Provide dummy org/repo to satisfy parser's later checks
        OssStats::CiStatsConfig.organizations =
          {'dummy' => {'repositories' => {'dummyrepo' => {}}}}

        parse_options
      end

      it 'attempts to load default config file if no --config is given' do
        default_loc = File.join(ENV['HOME'], '.config', 'oss_stats',
                                'ci_stats_config.rb')
        allow(OssStats::CiStatsConfig).to receive(:config_file).and_call_original

        allow(File).to receive(:exist?).with(default_loc).and_return(true)
        allow(File)
          .to receive(:exist?)
          .with(File.join(Dir.pwd, 'ci_stats_config.rb'))
          .and_return(false)
        allow(File)
          .to receive(:exist?)
          .with('/etc/ci_stats_config.rb')
          .and_return(false)

        expect(OssStats::CiStatsConfig).to receive(:from_file).with(default_loc)

        OssStats::CiStatsConfig.organizations =
          {'dummy' => {'repositories' => {'dummyrepo' => {}}}}
        parse_options # ARGV is empty
      end

      it 'CLI options override options loaded from a config file' do
        ARGV.concat(['--config', dummy_config_path, '--days', '20'])
        allow(File).to receive(:exist?).with(dummy_config_path).and_return(true)
        allow(File)
          .to receive(:expand_path)
          .with(dummy_config_path)
          .and_return(dummy_config_path)

        allow(OssStats::CiStatsConfig)
          .to receive(:from_file)
          .with(dummy_config_path) do
          OssStats::CiStatsConfig.default_days = 10
          OssStats::CiStatsConfig.organizations =
            {'dummyorg' => {'repositories' => {'dummyrepo' => {}}}}
        end

        parse_options
        # CLI option (20) should override file option (10)
        expect(OssStats::CiStatsConfig.default_days).to eq(20)
      end

      it 'CLI --org/--repo options override organizations from config file' do
        initial_orgs = {
          'org1' => { 'repositories' => { 'repo1a' => {}, 'repo1b' => {} } },
          'org2' => { 'repositories' => { 'repo2a' => {} } }
        }
        OssStats::CiStatsConfig.organizations = initial_orgs

        ARGV.concat(['--org', 'org_cli', '--repo', 'repo_cli'])
        parse_options

        expected_orgs = {
          'org_cli' => { 'repositories' => { 'repo_cli' => {} } }
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
            # Inherits global days
            'repo2a' => { 'branches' => ['feature_branch'] },
            # Inherits global days and branches
            'repo2b' => {}
          }
        }
      }
    end

    before(:each) do
      OssStats::CiStatsConfig.default_days = 30
      OssStats::CiStatsConfig.default_branches = ['default_global']
      OssStats::CiStatsConfig.organizations = sample_org_config
      OssStats::CiStatsConfig.mode = ['all'] # Needs a valid mode

      allow(self).to receive(:get_github_token!).and_return('fake_token')
      allow(Octokit::Client)
        .to receive(:new)
        .and_return(instance_double(Octokit::Client))

      allow(self).to receive(:get_pr_and_issue_stats)
      allow(self).to receive(:print_pr_or_issue_stats)
      allow(self).to receive(:get_failed_tests_from_ci)
      allow(self).to receive(:print_failed_tests_results) # Note: old name
      allow(self).to receive(:print_ci_status)           # Corrected name
      allow(self).to receive(:print_overall_summary)
      allow(self).to receive(:handle_include_list)
      allow(self).to receive(:sleep)
      allow(self).to receive(:rate_limited_sleep)
    end

    it 'correctly resolves settings for each repository' do
      expected_calls = [
        a_hash_including(org: 'org1', repo: 'repo1a', days: 5,
                         branches: ['main_repo1a']),
        a_hash_including(org: 'org1', repo: 'repo1b', days: 10,
                         branches: ['main_org1']),
        a_hash_including(org: 'org2', repo: 'repo2a', days: 30,
                         branches: ['feature_branch']),
        a_hash_including(org: 'org2', repo: 'repo2b', days: 30,
                         branches: ['default_global'])
      ]

      received_options_for_pr_stats = []
      allow(self)
        .to receive(:get_pr_and_issue_stats) do |_client, opts|
        received_options_for_pr_stats << opts
        { pr: {}, issue: {} } # Return dummy data
      end

      ARGV.clear
      allow(self).to receive(:parse_options) # Prevent re-parsing

      begin
        main
      rescue SystemExit
        # Expected if exit is called
      end

      expected_calls.each do |expected_option_set|
        expect(received_options_for_pr_stats)
          .to include(expected_option_set)
      end
      expect(received_options_for_pr_stats.size).to eq(expected_calls.size)
    end
  end
end
