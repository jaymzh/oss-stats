require 'rspec'
require 'set' # Required for Set literal in print_ci_status tests
require_relative '../src/ci_stats'
require_relative '../src/lib/oss_stats/ci_stats_config'

# Helper module to reset CiStatsConfig to its default state
module OssStats
  module CiStatsConfig
    def self.reset_defaults!
      @config_file = nil
      @config = nil
      self.default_branches = ['main']
      self.default_days = 30
      self.log_level = :info
      self.ci_timeout = 600
      self.github_api_endpoint = nil
      self.github_token = nil
      self.limit_gh_ops_per_minute = nil
      self.include_list = false
      self.organizations = {}
      self.mode = ['all']
    end
  end
end

RSpec.describe 'ci_stats main execution and output functions' do
  # Capture log output
  let(:log_output) { StringIO.new }
  let(:logger) do
    logger = Logger.new(log_output)
    logger.level = Logger::INFO # Default, can be changed in tests
    logger.formatter = proc { |severity, datetime, progname, msg|
      "#{msg}\n" # Simple formatter to match expected output style
    }
    logger
  end

  before(:each) do
    OssStats::CiStatsConfig.reset_defaults!
    ARGV.clear
    allow(OssStats::CiStatsConfig).to receive(:log).and_return(logger) # Use our logger

    # Stub methods that are not the focus of these specific unit tests
    allow_any_instance_of(Object).to receive(:exit).and_raise(SystemExit, "SystemExit called")
    allow_any_instance_of(Object).to receive(:sleep) # Stub sleep for rate_limited_sleep
    allow_any_instance_of(Object).to receive(:rate_limited_sleep) # Stub directly
  end

  # Helper to get captured log output as an array of lines
  def captured_log_lines
    log_output.string.split("\n")
  end

  describe '#print_pr_or_issue_stats' do
    let(:empty_stats) do
      {
        open: 0,
        closed: 0,
        opened_this_period: 0,
        avg_time_to_close_hours: 0,
        oldest_open: nil,
        oldest_open_days: nil,
        oldest_open_last_activity: nil,
        stale_count: 0
      }
    end
    let(:empty_list) { { open: [], closed: [] } }

    before(:each) do
      log_output.reopen('') # Clear log output before each test in this block
      OssStats::CiStatsConfig.include_list = false # Default for most tests here
    end

    context "for PRs" do
      let(:type) { 'PR' }

      it 'prints correctly with no open/closed PRs' do
        print_pr_or_issue_stats(type, empty_stats, empty_list)
        output = captured_log_lines
        expect(output).to include("Closed PRs: 0")
        expect(output).to include("Open PRs: 0")
        expect(output).to include("Opened This Period PRs: 0")
        expect(output).to include("Avg Time to Close PRs: 0.0 hours") # Assumes 0 prints as 0.0 hours
        expect(output).to include("Stale PRs (30+ days no activity): 0")
        # Check that oldest_open related lines are not printed when oldest_open is nil
        expect(output.join).not_to include("Oldest Open PR:")
        expect(output.join).not_to include("Oldest Open PR Days:")
        expect(output.join).not_to include("Oldest Open PR Last Activity:")
      end
    end

    context "for Issues" do
      let(:type) { 'Issue' }

      it 'prints correctly with no open/closed issues' do
        print_pr_or_issue_stats(type, empty_stats, empty_list)
        output = captured_log_lines
        expect(output).to include("Closed Issues: 0")
        expect(output).to include("Open Issues: 0")
        expect(output).to include("Opened This Period Issues: 0")
        expect(output).to include("Avg Time to Close Issues: 0.0 hours")
        expect(output).to include("Stale Issues (30+ days no activity): 0")
        expect(output.join).not_to include("Oldest Open Issue:")
      end
    end

    context "with data, no list (include_list = false)" do
      let(:stats_with_data) do
        {
          open: 1,
          closed: 1,
          opened_this_period: 1,
          avg_time_to_close_hours: 10.5, # Test < 24 hours
          oldest_open: double(
            created_at: Date.new(2023, 1, 15),
            updated_at: Date.new(2023, 2, 10),
            html_url: 'http://example.com/pr/1',
            number: 1,
            title: 'Oldest PR Title',
            user: double(login: 'user1')
          ),
          oldest_open_days: (Date.today - Date.new(2023, 1, 15)).to_i,
          oldest_open_last_activity: (Date.today - Date.new(2023, 2, 10)).to_i,
          stale_count: 1
        }
      end

      it 'prints PR stats correctly' do
        print_pr_or_issue_stats('PR', stats_with_data, empty_list)
        output = captured_log_lines
        expect(output).to include("Closed PRs: 1")
        expect(output).to include("Open PRs: 1")
        expect(output).to include("Opened This Period PRs: 1")
        expect(output).to include("Avg Time to Close PRs: 10.5 hours")
        expect(output).to include("Oldest Open PR: 2023-01-15 (Days: #{stats_with_data[:oldest_open_days]}, Last Activity: #{stats_with_data[:oldest_open_last_activity]} days ago) - http://example.com/pr/1 by user1: Oldest PR Title")
        expect(output).to include("Stale PRs (30+ days no activity): 1")
      end

      it 'prints Issue stats correctly' do
        print_pr_or_issue_stats('Issue', stats_with_data, empty_list)
        output = captured_log_lines
        expect(output).to include("Closed Issues: 1")
        expect(output).to include("Open Issues: 1")
        expect(output).to include("Opened This Period Issues: 1")
        expect(output).to include("Avg Time to Close Issues: 10.5 hours")
        expect(output).to include("Oldest Open Issue: 2023-01-15 (Days: #{stats_with_data[:oldest_open_days]}, Last Activity: #{stats_with_data[:oldest_open_last_activity]} days ago) - http://example.com/pr/1 by user1: Oldest PR Title")
        expect(output).to include("Stale Issues (30+ days no activity): 1")
      end
    end

    context "with data, with list (include_list = true)" do
      let(:item1) { double(title: 'Item 1 Title', number: 11, html_url: 'http://example.com/item/11', user: double(login: 'userA')) }
      let(:item2) { double(title: 'Item 2 Title', number: 12, html_url: 'http://example.com/item/12', user: double(login: 'userB')) }
      let(:item_list_with_data) { { open: [item1], closed: [item2] } }
      let(:stats_for_list) do
        # Similar to stats_with_data but might not need oldest_open if items are listed
        { open: 1, closed: 1, opened_this_period: 1, avg_time_to_close_hours: 0, oldest_open: nil, stale_count: 0 }
      end

      before(:each) do
        OssStats::CiStatsConfig.include_list = true
      end

      it 'prints PRs with item lists' do
        print_pr_or_issue_stats('PR', stats_for_list, item_list_with_data)
        output_str = log_output.string
        expect(output_str).to include("Closed PRs: 1")
        expect(output_str).to include("  - #12 userB: Item 2 Title - http://example.com/item/12")
        expect(output_str).to include("Open PRs: 1")
        expect(output_str).to include("  - #11 userA: Item 1 Title - http://example.com/item/11")
      end

      it 'prints Issues with item lists' do
        print_pr_or_issue_stats('Issue', stats_for_list, item_list_with_data)
        output_str = log_output.string
        expect(output_str).to include("Closed Issues: 1")
        expect(output_str).to include("  - #12 userB: Item 2 Title - http://example.com/item/12")
        expect(output_str).to include("Open Issues: 1")
        expect(output_str).to include("  - #11 userA: Item 1 Title - http://example.com/item/11")
      end
    end

    context "time formatting for avg_time_to_close" do
      let(:stats_placeholder) { { open: 0, closed: 0, opened_this_period: 0, oldest_open: nil, stale_count: 0 } }

      it 'prints in hours if less than 24 hours' do
        stats = stats_placeholder.merge(avg_time_to_close_hours: 10.5)
        print_pr_or_issue_stats('PR', stats, empty_list)
        expect(log_output.string).to include("Avg Time to Close PRs: 10.5 hours")
      end

      it 'prints in days if 24 hours or more' do
        stats = stats_placeholder.merge(avg_time_to_close_hours: 48.0)
        print_pr_or_issue_stats('PR', stats, empty_list)
        expect(log_output.string).to include("Avg Time to Close PRs: 2.0 days")
      end

      it 'prints in days if 24 hours (edge case)' do
        stats = stats_placeholder.merge(avg_time_to_close_hours: 24.0)
        print_pr_or_issue_stats('PR', stats, empty_list)
        expect(log_output.string).to include("Avg Time to Close PRs: 1.0 days")
      end
    end
  end

  describe '#print_ci_status' do
    before(:each) do
      log_output.reopen('') # Clear log output
    end

    it 'prints correctly when no failures on a branch' do
      test_failures = { 'main' => {} }
      print_ci_status(test_failures)
      output = captured_log_lines
      expect(output).to include("--- CI Status ---")
      expect(output).to include("Branch: main: No job failures found! :tada:")
    end

    it 'prints correctly with failures on a branch' do
      today = Date.today
      job_failures = Set[today, today - 1.day] # Using 1.day for ActiveSupport like behavior, or just Date.today - 1
      test_failures = { 'main' => { 'WorkflowA / Job1' => job_failures } }
      print_ci_status(test_failures)
      output = captured_log_lines
      expect(output).to include("--- CI Status ---")
      expect(output).to include("Branch: main has the following failures:")
      # The number of days is calculated as Set#size.
      expect(output).to include("        * WorkflowA / Job1: #{job_failures.size} days")
    end

    it 'prints correctly for multiple branches' do
      today = Date.today
      main_failures = { 'WorkflowA / Job1' => Set[today, today - 1] }
      develop_failures = { 'WorkflowB / JobX' => Set[today] }
      test_failures = {
        'main' => main_failures,
        'develop' => develop_failures,
        'feature_branch' => {}
      }
      print_ci_status(test_failures)
      output = captured_log_lines

      expect(output).to include("--- CI Status ---")
      expect(output).to include("Branch: main has the following failures:")
      expect(output).to include("        * WorkflowA / Job1: 2 days")
      expect(output).to include("Branch: develop has the following failures:")
      expect(output).to include("        * WorkflowB / JobX: 1 days") # Note: "1 days" is current output, could be "1 day"
      expect(output).to include("Branch: feature_branch: No job failures found! :tada:")
    end
  end

  describe '#main function orchestration' do
    let(:client_double) { instance_double(Octokit::Client) }
    let(:dummy_stats) { { pr: {}, issue: {}, pr_list: { open: [], closed: [] }, issue_list: { open: [], closed: [] } } }
    let(:dummy_ci_failures) { {} }

    before(:each) do
      # Config reset and ARGV clear are in top-level before(:each)
      # Logger is also set up in top-level before(:each)
      log_output.reopen('') # Clear log for each main orchestration test

      allow(self).to receive(:parse_options) # Stub, assume options are pre-set in CiStatsConfig
      allow(self).to receive(:get_github_token!).and_return('dummy_token')
      allow(Octokit::Client).to receive(:new).and_return(client_double)

      allow(self).to receive(:get_pr_and_issue_stats).and_return(dummy_stats)
      allow(self).to receive(:get_failed_tests_from_ci).and_return(dummy_ci_failures)

      # Spy on print methods to check if they are called, without re-testing their internal logic here
      allow(self).to receive(:print_pr_or_issue_stats)
      allow(self).to receive(:print_ci_status)
      allow(self).to receive(:print_overall_summary)
      allow(self).to receive(:handle_include_list)

      # Default org/repo for most tests
      OssStats::CiStatsConfig.organizations = {'org1' => {'repositories' => {'repo1' => {}}}}
    end

    context "mode variations" do
      it "runs PR/Issue stats when mode includes 'pr'" do
        OssStats::CiStatsConfig.mode = ['pr']
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self).to have_received(:print_pr_or_issue_stats).with('PR', anything, anything).at_least(:once)
        expect(self).not_to have_received(:get_failed_tests_from_ci)
        expect(self).not_to have_received(:print_ci_status)
      end

      it "runs PR/Issue stats when mode includes 'issue'" do
        OssStats::CiStatsConfig.mode = ['issue']
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self).to have_received(:print_pr_or_issue_stats).with('Issue', anything, anything).at_least(:once)
        expect(self).not_to have_received(:get_failed_tests_from_ci)
        expect(self).not_to have_received(:print_ci_status)
      end

      it "runs CI stats when mode includes 'ci'" do
        OssStats::CiStatsConfig.mode = ['ci']
        main
        expect(self).to have_received(:get_failed_tests_from_ci).at_least(:once)
        expect(self).to have_received(:print_ci_status).at_least(:once)
        expect(self).not_to have_received(:get_pr_and_issue_stats)
      end

      it "runs all stats when mode includes 'all'" do
        OssStats::CiStatsConfig.mode = ['all']
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self).to have_received(:print_pr_or_issue_stats).with('PR', anything, anything).at_least(:once)
        expect(self).to have_received(:print_pr_or_issue_stats).with('Issue', anything, anything).at_least(:once)
        expect(self).to have_received(:get_failed_tests_from_ci).at_least(:once)
        expect(self).to have_received(:print_ci_status).at_least(:once)
      end

      it "runs PR and CI stats when mode is ['pr', 'ci']" do
        OssStats::CiStatsConfig.mode = ['pr', 'ci']
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self).to have_received(:print_pr_or_issue_stats).with('PR', anything, anything).at_least(:once)
        # Should not print Issue stats if 'issue' is not in mode
        expect(self).not_to have_received(:print_pr_or_issue_stats).with('Issue', anything, anything)
        expect(self).to have_received(:get_failed_tests_from_ci).at_least(:once)
        expect(self).to have_received(:print_ci_status).at_least(:once)
      end
    end

    context "multiple repositories/organizations" do
      it "processes each configured repository" do
        OssStats::CiStatsConfig.organizations = {
          'org1' => {'repositories' => {'repo1' => {}, 'repo2' => {}}},
          'org2' => {'repositories' => {'repo3' => {}}}
        }
        OssStats::CiStatsConfig.mode = ['all'] # Ensure all parts run

        main

        # Check headers
        output_str = log_output.string
        expect(output_str).to include("Processing org1/repo1...")
        expect(output_str).to include("Processing org1/repo2...")
        expect(output_str).to include("Processing org2/repo3...")

        # Check calls to data fetching methods (should be once per repo)
        expect(self).to have_received(:get_pr_and_issue_stats).exactly(3).times
        expect(self).to have_received(:get_failed_tests_from_ci).exactly(3).times

        # Check calls to print methods (once per repo for each relevant type)
        expect(self).to have_received(:print_pr_or_issue_stats).with('PR', anything, anything).exactly(3).times
        expect(self).to have_received(:print_pr_or_issue_stats).with('Issue', anything, anything).exactly(3).times
        expect(self).to have_received(:print_ci_status).exactly(3).times
        expect(self).to have_received(:print_overall_summary).exactly(3).times
      end
    end

    context "no repositories to process" do
      it "warns and exits if organizations config is empty" do
        OssStats::CiStatsConfig.organizations = {}
        allow(self).to receive(:exit).with(0).and_raise(SystemExit.new("Clean exit"))

        expect { main }.to raise_error(SystemExit, "Clean exit")

        output_str = log_output.string
        # The main script uses `log.warn` which should be captured by our logger if level is appropriate.
        # Logger level is INFO by default. Let's ensure warn is also captured.
        # Or, we can check the specific log call if `log` is the OssStats::CiStatsConfig.log
        expect(OssStats::CiStatsConfig.log).to have_received(:warn).with('No organizations/repositories to process. Exiting.')
      end
    end
  end
end
