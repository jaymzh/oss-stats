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
  let(:log_output) { StringIO.new }
  let(:logger) do
    logger = Logger.new(log_output)
    logger.level = Logger::INFO
    logger.formatter = proc do |_severity, _datetime, _progname, msg|
      "#{msg}\n" # Simple formatter
    end
    logger
  end

  before(:each) do
    OssStats::CiStatsConfig.reset_defaults!
    ARGV.clear
    # Ensure OssStats::Log.log (used by top-level log method in ci_stats.rb)
    # returns our test logger.
    allow(OssStats::Log).to receive(:log).and_return(logger)
    # Also stub direct calls to OssStats::CiStatsConfig.log if any component uses it.
    allow(OssStats::CiStatsConfig).to receive(:log).and_return(logger)

    allow_any_instance_of(Object)
      .to receive(:exit)
      .and_raise(SystemExit, "SystemExit called")
    allow_any_instance_of(Object).to receive(:sleep)
    allow_any_instance_of(Object).to receive(:rate_limited_sleep)
  end

  def captured_log_lines
    log_output.string.split("\n")
  end

  describe '#print_pr_or_issue_stats' do
    let(:empty_specific_stats) do # Renamed from empty_stats
      {
        open: 0, closed: 0, opened_this_period: 0,
        avg_time_to_close_hours: 0, oldest_open: nil,
        oldest_open_days: nil, oldest_open_last_activity: nil,
        stale_count: 0
      }
    end
    let(:empty_specific_list_data) { { open: [], closed: [] } } # Renamed

    before(:each) do
      log_output.reopen('') # Clear log output
      OssStats::CiStatsConfig.include_list = false
    end

    context "for PRs" do
      let(:type) { 'PR' }
      let(:data_for_pr_print) do
        {
          pr: empty_specific_stats,
          pr_list: empty_specific_list_data,
          # Include empty issue data to ensure no bleed-over and match typical full data structure
          issue: empty_specific_stats,
          issue_list: empty_specific_list_data
        }
      end

      it 'prints correctly with no open/closed PRs' do
        print_pr_or_issue_stats(data_for_pr_print, type, OssStats::CiStatsConfig.include_list)
        output = captured_log_lines
        expect(output).to include("Closed PRs: 0")
        expect(output).to include("Open PRs: 0")
        expect(output).to include("Opened This Period PRs: 0")
        expect(output).to include("Avg Time to Close PRs: 0.0 hours")
        expect(output).to include("Stale PRs (30+ days no activity): 0")
        expect(output.join).not_to include("Oldest Open PR:")
        expect(output.join).not_to include("Oldest Open PR Days:")
        expect(output.join).not_to include("Oldest Open PR Last Activity:")
      end
    end

    context "for Issues" do
      let(:type) { 'Issue' }
      let(:data_for_issue_print) do
        {
          issue: empty_specific_stats,
          issue_list: empty_specific_list_data,
          pr: empty_specific_stats, # Include empty PR data
          pr_list: empty_specific_list_data
        }
      end

      it 'prints correctly with no open/closed issues' do
        print_pr_or_issue_stats(data_for_issue_print, type, OssStats::CiStatsConfig.include_list)
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
      let(:oldest_item_double) do
        double(
          created_at: Date.new(2023, 1, 15),
          updated_at: Date.new(2023, 2, 10),
          html_url: 'http://example.com/item/1',
          number: 1,
          title: 'Oldest Item Title',
          user: double(login: 'user1')
        )
      end
      let(:stats_with_data_content) do # Content for PR or Issue specific stats
        {
          open: 1, closed: 1, opened_this_period: 1,
          avg_time_to_close_hours: 10.5, oldest_open: oldest_item_double,
          oldest_open_days: (Date.today - Date.new(2023, 1, 15)).to_i,
          oldest_open_last_activity: (Date.today - Date.new(2023, 2, 10)).to_i,
          stale_count: 1
        }
      end
      let(:expected_oldest_line_regex) do
        # Adjusted regex to be more flexible with PR/Issue type in string
        /Oldest Open (?:PR|Issue): 2023-01-15 \(Days: \d+, Last Activity: \d+ days ago\) - http:\/\/example.com\/item\/1 by user1: Oldest Item Title/
      end


      it 'prints PR stats correctly' do
        data_to_print = { pr: stats_with_data_content, pr_list: empty_specific_list_data }
        print_pr_or_issue_stats(data_to_print, 'PR', OssStats::CiStatsConfig.include_list)
        output = captured_log_lines
        expect(output).to include("Closed PRs: 1")
        expect(output).to include("Open PRs: 1")
        expect(output).to include("Opened This Period PRs: 1")
        expect(output).to include("Avg Time to Close PRs: 10.5 hours")
        expect(output.join).to match(expected_oldest_line_regex)
        expect(output).to include("Stale PRs (30+ days no activity): 1")
      end

      it 'prints Issue stats correctly' do
        data_to_print = { issue: stats_with_data_content, issue_list: empty_specific_list_data }
        print_pr_or_issue_stats(data_to_print, 'Issue', OssStats::CiStatsConfig.include_list)
        output = captured_log_lines
        expect(output).to include("Closed Issues: 1")
        expect(output).to include("Open Issues: 1")
        expect(output).to include("Opened This Period Issues: 1")
        expect(output).to include("Avg Time to Close Issues: 10.5 hours")
        expect(output.join).to match(expected_oldest_line_regex)
        expect(output).to include("Stale Issues (30+ days no activity): 1")
      end
    end

    context "with data, with list (include_list = true)" do
      let(:item1) do
        double(title: 'Item 1 Title', number: 11,
               html_url: 'http://example.com/item/11',
               user: double(login: 'userA'))
      end
      let(:item2) do
        double(title: 'Item 2 Title', number: 12,
               html_url: 'http://example.com/item/12',
               user: double(login: 'userB'))
      end
      let(:list_data_content) { { open: [item1], closed: [item2] } }
      let(:stats_content_for_list) do
        { open: 1, closed: 1, opened_this_period: 1,
          avg_time_to_close_hours: 0, oldest_open: nil, stale_count: 0 }
      end

      before(:each) do
        OssStats::CiStatsConfig.include_list = true
      end

      it 'prints PRs with item lists' do
        data_to_print = { pr: stats_content_for_list, pr_list: list_data_content }
        print_pr_or_issue_stats(data_to_print, 'PR', OssStats::CiStatsConfig.include_list)
        output_str = log_output.string
        expect(output_str).to include("Closed PRs: 1")
        expect(output_str)
          .to include("  - #[#{item2.number} #{item2.user.login}: #{item2.title} - #{item2.html_url}")
        expect(output_str).to include("Open PRs: 1")
        expect(output_str)
          .to include("  - #[#{item1.number} #{item1.user.login}: #{item1.title} - #{item1.html_url}")
      end

      it 'prints Issues with item lists' do
        data_to_print = { issue: stats_content_for_list, issue_list: list_data_content }
        print_pr_or_issue_stats(data_to_print, 'Issue', OssStats::CiStatsConfig.include_list)
        output_str = log_output.string
        expect(output_str).to include("Closed Issues: 1")
        expect(output_str)
          .to include("  - #[#{item2.number} #{item2.user.login}: #{item2.title} - #{item2.html_url}")
        expect(output_str).to include("Open Issues: 1")
        expect(output_str)
          .to include("  - #[#{item1.number} #{item1.user.login}: #{item1.title} - #{item1.html_url}")
      end
    end

    context "time formatting for avg_time_to_close" do
      let(:stats_placeholder_content) do # Content for PR/Issue specific stats
        { open: 0, closed: 0, opened_this_period: 0, oldest_open: nil,
          stale_count: 0 }
      end

      it 'prints in hours if less than 24 hours' do
        stats = stats_placeholder_content.merge(avg_time_to_close_hours: 10.5)
        data_to_print = { pr: stats, pr_list: empty_specific_list_data }
        print_pr_or_issue_stats(data_to_print, 'PR', OssStats::CiStatsConfig.include_list)
        expect(log_output.string)
          .to include("Avg Time to Close PRs: 10.5 hours")
      end

      it 'prints in days if 24 hours or more' do
        stats = stats_placeholder_content.merge(avg_time_to_close_hours: 48.0)
        data_to_print = { pr: stats, pr_list: empty_specific_list_data }
        print_pr_or_issue_stats(data_to_print, 'PR', OssStats::CiStatsConfig.include_list)
        expect(log_output.string)
          .to include("Avg Time to Close PRs: 2.0 days")
      end

      it 'prints in days if 24 hours (edge case)' do
        stats = stats_placeholder_content.merge(avg_time_to_close_hours: 24.0)
        data_to_print = { pr: stats, pr_list: empty_specific_list_data }
        print_pr_or_issue_stats(data_to_print, 'PR', OssStats::CiStatsConfig.include_list)
        expect(log_output.string)
          .to include("Avg Time to Close PRs: 1.0 days")
      end
    end
  end

  describe '#print_ci_status' do
    before(:each) do
      log_output.reopen('') # Clear log output
    end

    it 'prints correctly when no failures on a branch' do
      test_failures = { 'main' => {} }
      # The second argument to print_ci_status was options, which is not used.
      # Passing empty hash for now.
      print_ci_status(test_failures, {})
      output = captured_log_lines
      expect(output).to include("--- CI Status ---")
      expect(output).to include("Branch: main: No job failures found! :tada:")
    end

    it 'prints correctly with failures on a branch' do
      today = Date.today
      job_failures = Set[today, today - 1] # Corrected: removed .day
      test_failures = { 'main' => { 'WorkflowA / Job1' => job_failures } }
      print_ci_status(test_failures, {})
      output = captured_log_lines
      expect(output).to include("--- CI Status ---")
      expect(output).to include("Branch: main has the following failures:")
      expect(output)
        .to include("        * WorkflowA / Job1: #{job_failures.size} days")
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
      print_ci_status(test_failures, {})
      output = captured_log_lines

      expect(output).to include("--- CI Status ---")
      expect(output).to include("Branch: main has the following failures:")
      expect(output).to include("        * WorkflowA / Job1: 2 days")
      expect(output).to include("Branch: develop has the following failures:")
      expect(output).to include("        * WorkflowB / JobX: 1 days")
      expect(output)
        .to include("Branch: feature_branch: No job failures found! :tada:")
    end
  end

  describe '#main function orchestration' do
    let(:client_double) { instance_double(Octokit::Client) }
    let(:dummy_data_for_main) do # Renamed from dummy_stats to avoid confusion
      {
        pr: {open: 0, closed: 0, opened_this_period: 0, avg_time_to_close_hours: 0, oldest_open: nil, stale_count: 0},
        issue: {open: 0, closed: 0, opened_this_period: 0, avg_time_to_close_hours: 0, oldest_open: nil, stale_count: 0},
        pr_list: { open: [], closed: [] },
        issue_list: { open: [], closed: [] }
      }
    end
    let(:dummy_ci_failures) { {} }

    before(:each) do
      log_output.reopen('')
      allow(self).to receive(:parse_options)
      allow(self).to receive(:get_github_token!).and_return('dummy_token')
      allow(Octokit::Client).to receive(:new).and_return(client_double)

      allow(self).to receive(:get_pr_and_issue_stats).and_return(dummy_data_for_main)
      allow(self)
        .to receive(:get_failed_tests_from_ci)
        .and_return(dummy_ci_failures)

      allow(self).to receive(:print_pr_or_issue_stats)
      allow(self).to receive(:print_ci_status)
      allow(self).to receive(:print_overall_summary)
      allow(self).to receive(:handle_include_list)

      OssStats::CiStatsConfig.organizations =
        {'org1' => {'repositories' => {'repo1' => {}}}}
    end

    context "mode variations" do
      it "runs PR/Issue stats when mode includes 'pr'" do
        OssStats::CiStatsConfig.mode = ['pr']
        OssStats::CiStatsConfig.include_list = false # Example boolean value
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'PR', false).at_least(:once)
        expect(self).not_to have_received(:get_failed_tests_from_ci)
        expect(self).not_to have_received(:print_ci_status)
      end

      it "runs PR/Issue stats when mode includes 'issue'" do
        OssStats::CiStatsConfig.mode = ['issue']
        OssStats::CiStatsConfig.include_list = true # Example boolean value
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'Issue', true).at_least(:once)
        expect(self).not_to have_received(:get_failed_tests_from_ci)
        expect(self).not_to have_received(:print_ci_status)
      end

      it "runs CI stats when mode includes 'ci'" do
        OssStats::CiStatsConfig.mode = ['ci']
        main
        expect(self).to have_received(:get_failed_tests_from_ci).at_least(:once)
        # The second argument to print_ci_status is options, which seems to be an empty hash in main
        expect(self).to have_received(:print_ci_status).with(dummy_ci_failures, {}).at_least(:once)
        expect(self).not_to have_received(:get_pr_and_issue_stats)
      end

      it "runs all stats when mode includes 'all'" do
        OssStats::CiStatsConfig.mode = ['all']
        OssStats::CiStatsConfig.include_list = false # Example boolean value
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'PR', false).at_least(:once)
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'Issue', false).at_least(:once)
        expect(self).to have_received(:get_failed_tests_from_ci).at_least(:once)
        expect(self).to have_received(:print_ci_status).with(dummy_ci_failures, {}).at_least(:once)
      end

      it "runs PR and CI stats when mode is ['pr', 'ci']" do
        OssStats::CiStatsConfig.mode = ['pr', 'ci']
        OssStats::CiStatsConfig.include_list = false
        main
        expect(self).to have_received(:get_pr_and_issue_stats).at_least(:once)
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'PR', false).at_least(:once)
        expect(self)
          .not_to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'Issue', false) # Not with 'Issue'
        expect(self).to have_received(:get_failed_tests_from_ci).at_least(:once)
        expect(self).to have_received(:print_ci_status).with(dummy_ci_failures, {}).at_least(:once)
      end
    end

    context "multiple repositories/organizations" do
      it "processes each configured repository" do
        OssStats::CiStatsConfig.organizations = {
          'org1' => {'repositories' => {'repo1' => {}, 'repo2' => {}}},
          'org2' => {'repositories' => {'repo3' => {}}}
        }
        OssStats::CiStatsConfig.mode = ['all']
        OssStats::CiStatsConfig.include_list = false

        main

        output_content = log_output.string # Changed variable name for clarity
        expect(output_content).to include("Processing org1/repo1...")
        expect(output_content).to include("Processing org1/repo2...")
        expect(output_content).to include("Processing org2/repo3...")

        expect(self).to have_received(:get_pr_and_issue_stats).exactly(3).times
        expect(self).to have_received(:get_failed_tests_from_ci).exactly(3).times
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'PR', false).exactly(3).times
        expect(self)
          .to have_received(:print_pr_or_issue_stats)
          .with(dummy_data_for_main, 'Issue', false).exactly(3).times
        expect(self).to have_received(:print_ci_status).with(dummy_ci_failures, {}).exactly(3).times
        expect(self).to have_received(:print_overall_summary).exactly(3).times
      end
    end

    context "no repositories to process" do
      it "warns and exits if organizations config is empty" do
        OssStats::CiStatsConfig.organizations = {}
        allow(self).to receive(:exit).with(0).and_raise(SystemExit.new("Clean exit"))

        # Spy on the logger's warn method for this specific test,
        # ensuring it's our test logger instance being checked.
        allow(logger).to receive(:warn).and_call_original

        expect { main }.to raise_error(SystemExit, "Clean exit")

        expect(logger) # Check the test logger instance
          .to have_received(:warn)
          .with('No organizations/repositories to process. Exiting.')
      end
    end
  end
end
