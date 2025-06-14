require 'rspec'
require 'octokit'
require_relative '../src/ci_stats'
require_relative '../src/lib/oss_stats/ci_stats_config'

RSpec.describe 'ci_status' do
  let(:client) { instance_double(Octokit::Client) }
  let(:options) do
    {
      org: 'test_org',
      repo: 'test_repo',
      days: 30,
      branches: ['main'],
    }
  end

  before do
    allow(client).to receive(:issues).and_return([])
    allow(client).to receive(:pull_requests).and_return([])
    allow(client).to receive(:workflows).and_return(double(workflows: []))
    allow(client).to receive(:workflow_runs).and_return(
      double(workflow_runs: []),
    )
    allow(client).to receive(:workflow_run_jobs).and_return(double(jobs: []))
  end

  describe '#rate_limited_sleep' do
    after(:each) do
      OssStats::CiStatsConfig.limit_gh_ops_per_minute = nil
    end

    it 'sleeps for the correct amount of time based on the rate limit' do
      OssStats::CiStatsConfig.limit_gh_ops_per_minute = 60
      expect(self).to receive(:sleep).with(1.0)
      rate_limited_sleep
    end

    it 'does not sleep if the rate limit is not set' do
      OssStats::CiStatsConfig.limit_gh_ops_per_minute = nil
      expect(self).not_to receive(:sleep)
      rate_limited_sleep
    end

    it 'does not sleep if the rate limit is 0' do
      OssStats::CiStatsConfig.limit_gh_ops_per_minute = 0
      expect(self).not_to receive(:sleep)
      rate_limited_sleep
    end
  end

  describe '#get_pr_and_issue_stats' do
    it 'fetches PR and issue stats from GitHub' do
      allow(client).to receive(:issues).with(
        'test_org/test_repo',
        hash_including(page: 1),
      ).and_return(
        [
          # closed PR
          double(
            created_at: Date.today - 7,
            closed_at: Date.today - 5,
            pull_request: double(
              merged_at: Date.today - 5,
            ),
            updated_at: Date.today - 3,
            labels: [],
          ),
          # open Issue
          double(
            created_at: Date.today - 7,
            closed_at: nil,
            pull_request: nil,
            updated_at: Date.today - 3,
            labels: [],
          ),
        ],
      )
      allow(client).to receive(:issues).with(
        'test_org/test_repo',
        hash_including(page: 2),
      ).and_return([])

      stats = get_pr_and_issue_stats(client, options)

      expect(stats[:pr][:open]).to eq(0)
      expect(stats[:pr][:closed]).to eq(1)
      expect(stats[:issue][:open]).to eq(1)
      expect(stats[:issue][:closed]).to eq(0)
    end

    it 'handles empty responses gracefully' do
      allow(client).to receive(:issues).and_return([])

      stats = get_pr_and_issue_stats(client, options)

      expect(stats[:pr][:open]).to eq(0)
      expect(stats[:issue][:open]).to eq(0)
    end
  end

  describe '#get_failed_tests_from_ci' do
    it 'fetches failed tests from CI workflows' do
      allow(client).to receive(:workflows).and_return(
        double(workflows: [double(id: 1, name: 'Test Workflow')]),
      )
      allow(client).to receive(:workflow_runs).with(
        'test_org/test_repo',
        1,
        hash_including(page: 1),
      ).and_return(
        double(workflow_runs: [
                 double(id: 1, created_at: Date.today - 5),
               ]),
      )
      allow(client).to receive(:workflow_runs).with(
        'test_org/test_repo',
        1,
        hash_including(page: 2),
      ).and_return(double(workflow_runs: []))
      allow(client).to receive(:workflow_run_jobs).and_return(
        double(jobs: [
                 double(name: 'Test Job', conclusion: 'failure'),
               ]),
      )

      failed_tests = get_failed_tests_from_ci(client, options)

      expect(failed_tests['main']['Test Workflow / Test Job'])
        .to include(Date.today - 5)
    end

    it 'handles no failures gracefully' do
      allow(client).to receive(:workflows).and_return(
        double(workflows: [double(id: 1, name: 'Test Workflow')]),
      )
      allow(client).to receive(:workflow_runs).and_return(
        double(workflow_runs: []),
      )

      failed_tests = get_failed_tests_from_ci(client, options)

      expect(failed_tests['main']).to be_empty
    end

    describe 'Buildkite Integration' do
      let(:mock_buildkite_client) { instance_double(OssStats::BuildkiteClient) }
      # Updated README content to match the new regex
      let(:readme_content_with_badge) do
        <<~README
          Some text before
          [![Build Status](https://badge.buildkite.com/someuuid.svg?branch=main)](https://buildkite.com/test-buildkite-org/actual-pipeline-name)
          More text [![Another Badge](https://badge.buildkite.com/another.svg)](https://buildkite.com/other-org/other-pipeline)
          Some text after
        README
      end
      let(:readme_content_with_badge_alternative_format) do
        # Test with a slightly different markdown image link format
        <<~README
        [![] (https://badge.buildkite.com/short-uuid.svg)](https://buildkite.com/test-buildkite-org/another-actual-pipeline)
        README
      end
      let(:readme_content_without_badge) { "This README has no Buildkite badge, only text." }
      let(:settings_with_buildkite_token) { options.merge(buildkite_token: 'fake-bk-token') }


      before do
        # Stub for get_buildkite_token!
        allow(self).to receive(:get_buildkite_token!).with(OssStats::CiStatsConfig).and_return('fake-bk-token')
        # Common stub for BuildkiteClient instantiation
        allow(OssStats::BuildkiteClient).to receive(:new).and_return(mock_buildkite_client)
        # Common stub for get_pipeline_builds
        allow(mock_buildkite_client).to receive(:get_pipeline_builds).and_return([])
      end

      context 'when repository has a Buildkite badge in README' do
        let(:readme_double) { double(content: readme_content_with_badge) }
        let(:accept_header) { 'application/vnd.github.html+json' }
        let(:repo_full_name) { "#{options[:org]}/#{options[:repo]}" }

        before do
          allow(client).to receive(:readme)
            .with(repo_full_name, accept: accept_header)
            .and_return(readme_double)
        end

        it 'calls BuildkiteClient with correctly parsed slugs and processes results' do
          expect(OssStats::BuildkiteClient).to receive(:new)
            .with('fake-bk-token', 'test-buildkite-org')
            .and_return(mock_buildkite_client)
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with('actual-pipeline-name', nil, Date.today - options[:days], Date.today)
            .and_return([
              { 'node' => {
                  'createdAt' => (Date.today - 1).to_s, 'state' => 'FAILED',
                  'jobs' => { 'edges' => [
                      { 'node' => { 'label' => 'Test Job 1', 'state' => 'FAILED' } },
                      { 'node' => { 'label' => 'Test Job 2', 'state' => 'PASSED' } }
                  ]}
              }}
            ])
          failed_tests = get_failed_tests_from_ci(client, settings_with_buildkite_token)
          job1_key = 'Buildkite / test-buildkite-org/actual-pipeline-name / Test Job 1'
          job2_key = 'Buildkite / test-buildkite-org/actual-pipeline-name / Test Job 2'
          expect(failed_tests['main'][job1_key]).to include(Date.today - 1)
          expect(failed_tests['main']).not_to have_key(job2_key)
        end

        it 'correctly parses alternative badge markdown format' do
          allow(client).to receive(:readme)
            .with(repo_full_name, accept: accept_header)
            .and_return(double(content: readme_content_with_badge_alternative_format))
          expect(OssStats::BuildkiteClient).to receive(:new)
            .with('fake-bk-token', 'test-buildkite-org')
            .and_return(mock_buildkite_client)
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with('another-actual-pipeline', nil, Date.today - options[:days], Date.today)
            .and_return([]) # Not testing results here, just parsing
          get_failed_tests_from_ci(client, settings_with_buildkite_token)
        end

        it 'handles no failed builds from Buildkite' do
          allow(mock_buildkite_client).to receive(:get_pipeline_builds).and_return([
            {
              'node' => {
                'createdAt' => (Date.today - 1).to_s,
                'state' => 'PASSED',
                'jobs' => {
                  'edges' => [
                    { 'node' => { 'label' => 'Test Job 1', 'state' => 'PASSED' } }
                  ]
                }
              }
            }
          ])
          failed_tests = get_failed_tests_from_ci(client, settings_with_buildkite_token)
          buildkite_job_keys = failed_tests['main'].keys.select { |k| k.start_with?('Buildkite /') }
          expect(buildkite_job_keys).to be_empty
        end

        context 'with ongoing failures' do
          let(:days_to_check) { 5 }
          let(:options_for_ongoing) { options.merge(days: days_to_check) }
          let(:today) { Date.today }
          let(:job1_name) { 'Failing Job' }
          let(:job2_name) { 'Failing Then Passing Job' }
          let(:pipeline_name) { 'actual-pipeline-name' }
          let(:job1_key) { "Buildkite / test-buildkite-org/#{pipeline_name} / #{job1_name}" }
          let(:job2_key) { "Buildkite / test-buildkite-org/#{pipeline_name} / #{job2_name}" }

          let(:mock_builds_for_ongoing_test) do
            # Helper to create a job node
            def job_node(label, state)
              { 'node' => { 'label' => label, 'state' => state } }
            end
            # Helper to create a build node
            def build_node(created_at_val, state_val, jobs_array)
              { 'node' => { 'createdAt' => created_at_val.to_s, 'state' => state_val,
                            'jobs' => { 'edges' => jobs_array } } }
            end

            [
              build_node(today - days_to_check + 1, 'FAILED', [job_node(job1_name, 'FAILED')]),
              build_node(today - days_to_check + 2, 'FAILED', [job_node(job2_name, 'FAILED')]),
              build_node(today - days_to_check + 3, 'PASSED', [job_node(job2_name, 'PASSED')]),
              build_node(today - days_to_check + 4, 'FAILED', [job_node(job1_name, 'FAILED')])
            ].sort_by { |b| DateTime.parse(b['node']['createdAt']) }
          end

          it 'correctly reports days for ongoing and fixed failures' do
            allow(mock_buildkite_client).to receive(:get_pipeline_builds)
              .with(pipeline_name, nil, today - days_to_check, today)
              .and_return(mock_builds_for_ongoing_test)

            current_settings = options_for_ongoing.merge(buildkite_token: 'fake-bk-token')
            failed_tests = get_failed_tests_from_ci(client, current_settings)

            # Job 1 (Failing Job): Expected to fail from its first failure date up to today.
            first_fail_date_job1 = today - days_to_check + 1
            expected_job1_dates = Set.new((first_fail_date_job1..today).to_a)
            expect(failed_tests['main'][job1_key]).to eq(expected_job1_dates)
            expect(failed_tests['main'][job1_key].size).to eq(days_to_check)

            # Job 2 (Failing Then Passing Job): Expected to fail only on the day it actually failed.
            fail_date_job2 = today - days_to_check + 2
            expected_job2_dates = Set.new([fail_date_job2])
            expect(failed_tests['main'][job2_key]).to eq(expected_job2_dates)
            expect(failed_tests['main'][job2_key].size).to eq(1)
          end
        end
      end

      context 'when repository does not have a Buildkite badge' do
        before do
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}", accept: 'application/vnd.github.html+json')
            .and_return(double(content: readme_content_without_badge))
        end

        it 'does not call BuildkiteClient' do
          expect(OssStats::BuildkiteClient).not_to receive(:new)
          expect(mock_buildkite_client).not_to receive(:get_pipeline_builds)
          get_failed_tests_from_ci(client, settings_with_buildkite_token)
        end
      end

      context 'when README is not found' do
        before do
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}", accept: 'application/vnd.github.html+json')
            .and_raise(Octokit::NotFound)
        end

        it 'handles the error and does not call BuildkiteClient' do
          expect(OssStats::BuildkiteClient).not_to receive(:new)
          expect_any_instance_of(OssStats::Log).to receive(:warn).with(/README.md not found for repo test_org\/test_repo/)
          get_failed_tests_from_ci(client, settings_with_buildkite_token)
        end
      end

      context 'when Buildkite API call fails' do
        before do
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}", accept: 'application/vnd.github.html+json')
            .and_return(double(content: readme_content_with_badge))
          allow(mock_buildkite_client).to receive(:get_pipeline_builds).and_raise(StandardError.new("Buildkite API Error"))
        end

        it 'handles the error gracefully and logs it' do
          expect_any_instance_of(OssStats::Log).to receive(:error).with(/Error during Buildkite integration for test_org\/test_repo: Buildkite API Error/)
          failed_tests = get_failed_tests_from_ci(client, settings_with_buildkite_token)
          buildkite_job_keys = failed_tests['main'].keys.select { |k| k.start_with?('Buildkite /') }
          expect(buildkite_job_keys).to be_empty
        end
      end

      context 'when Buildkite token is not available' do
        before do
          # Mock get_buildkite_token! to return nil
          allow(self).to receive(:get_buildkite_token!).with(OssStats::CiStatsConfig).and_return(nil)
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}", accept: 'application/vnd.github.html+json')
            .and_return(double(content: readme_content_with_badge)) # Still need readme to trigger the check
        end

        it 'logs a warning and skips Buildkite processing' do
          expect_any_instance_of(OssStats::Log).to receive(:warn).with(/Buildkite token not available. Skipping Buildkite integration for test_org\/test_repo/)
          expect(OssStats::BuildkiteClient).not_to receive(:new)
          get_failed_tests_from_ci(client, options) # options doesn't have token, relying on the mocked get_buildkite_token!
        end
      end
    end
  end
end

# Tests for parse_options are minimal as it's mostly framework.
# We'll add a specific test for --buildkite-token.
describe '#parse_options' do
  # Helper to run parse_options with specific ARGV
  def run_parse_options(argv)
    stub_const('ARGV', argv)
    # Reset Mixlib::Config defaults for each test run if necessary,
    # or ensure options are applied to a fresh config object.
    # For this test, we'll check what `parse_options` itself does.
    # `parse_options` calls OssStats::CiStatsConfig.merge!(options),
    # so we inspect OssStats::CiStatsConfig after the call.

    # Reset relevant config before each parse_options call for isolated testing
    OssStats::CiStatsConfig.buildkite_token = nil
    OssStats::CiStatsConfig.github_token = nil # Example of another potentially set option

    parse_options
  end

  context 'when --buildkite-token is provided' do
    it 'sets the buildkite_token in CiStatsConfig' do
      run_parse_options(['--buildkite-token', 'my-secret-bk-token'])
      expect(OssStats::CiStatsConfig.buildkite_token).to eq('my-secret-bk-token')
    end
  end

  context 'when --buildkite-token is not provided' do
    it 'does not set the buildkite_token in CiStatsConfig if not already set' do
      run_parse_options([]) # No relevant args
      expect(OssStats::CiStatsConfig.buildkite_token).to be_nil
    end
  end

  # Example of testing another option to ensure the setup is correct
  context 'when --github-token is provided' do
    it 'sets the github_token in CiStatsConfig' do
      run_parse_options(['--github-token', 'my-gh-token'])
      expect(OssStats::CiStatsConfig.github_token).to eq('my-gh-token')
    end
  end
end

describe '#print_ci_status' do
  let(:log_mock) { instance_double(OssStats::Log).as_null_object } # Using as_null_object to ignore other log calls

  before do
    # Ensure 'log' method within the test context returns our mock
    # This assumes print_ci_status uses a globally available 'log' method or one passed in.
    # Based on src/ci_stats.rb, it uses a global `log` object.
    # We need to allow the global `log` to receive calls.
    # A simple way is to allow `OssStats::Log.instance` if it's a singleton,
    # or ensure the `log` method used by `print_ci_status` is stubbed.
    # For simplicity, let's assume `print_ci_status` has access to `log` that we can mock.
    # Re-reading the `src/ci_stats.rb`, `log` is indeed a global accessor to `OssStats::Log.instance`.
    allow(OssStats::Log.instance).to receive(:info) # Stub .info on the actual instance
  end

  context 'with only GitHub Actions failures' do
    let(:test_failures) do
      {
        'main' => {
          'GH Workflow / Job A' => Set[Date.today, Date.today - 1],
          'GH Workflow / Job B' => Set[Date.today]
        }
      }
    end

    it 'prints GitHub Actions failures correctly' do
      expect(OssStats::Log.instance).to receive(:info).with("\n* CI Stats:")
      expect(OssStats::Log.instance).to receive(:info).with("    * Branch: `main` has the following failures:")
      expect(OssStats::Log.instance).to receive(:info).with("        * GH Workflow / Job A: 2 days")
      expect(OssStats::Log.instance).to receive(:info).with("        * GH Workflow / Job B: 1 days")
      print_ci_status(test_failures, {})
    end
  end

  context 'with only Buildkite failures' do
    let(:test_failures) do
      {
        'main' => {
          'Buildkite / org/pipe / Job X' => Set[Date.today],
          'Buildkite / org/pipe / Job Y' => Set[Date.today, Date.today - 1, Date.today - 2]
        }
      }
    end

    it 'prints Buildkite failures correctly' do
      expect(OssStats::Log.instance).to receive(:info).with("\n* CI Stats:")
      expect(OssStats::Log.instance).to receive(:info).with("    * Branch: `main` has the following failures:")
      expect(OssStats::Log.instance).to receive(:info).with("        * Buildkite / org/pipe / Job X: 1 days")
      expect(OssStats::Log.instance).to receive(:info).with("        * Buildkite / org/pipe / Job Y: 3 days")
      print_ci_status(test_failures, {})
    end
  end

  context 'with mixed GitHub Actions and Buildkite failures' do
    let(:test_failures) do
      {
        'main' => {
          'GH Workflow / Job A' => Set[Date.today],
          'Buildkite / org/pipe / Job X' => Set[Date.today - 1],
          'GH Workflow / Job C' => Set[Date.today - 2, Date.today - 3]
        }
      }
    end

    it 'prints mixed failures correctly and sorted' do
      expect(OssStats::Log.instance).to receive(:info).with("\n* CI Stats:")
      expect(OssStats::Log.instance).to receive(:info).with("    * Branch: `main` has the following failures:")
      # Sorted order: Buildkite job first, then GH jobs
      expect(OssStats::Log.instance).to receive(:info).with("        * Buildkite / org/pipe / Job X: 1 days").ordered
      expect(OssStats::Log.instance).to receive(:info).with("        * GH Workflow / Job A: 1 days").ordered
      expect(OssStats::Log.instance).to receive(:info).with("        * GH Workflow / Job C: 2 days").ordered
      print_ci_status(test_failures, {})
    end
  end

  context 'with no failures' do
    let(:test_failures) { { 'main' => {} } }

    it 'prints the no failures message' do
      expect(OssStats::Log.instance).to receive(:info).with("\n* CI Stats:")
      expect(OssStats::Log.instance).to receive(:info).with("    * Branch: `main`: No job failures found! :tada:")
      print_ci_status(test_failures, {})
    end
  end

  context 'with failures on multiple branches' do
    let(:test_failures) do
      {
        'main' => { 'GH Workflow / Job A' => Set[Date.today] },
        'develop' => { 'Buildkite / org/pipe / Job X' => Set[Date.today - 1, Date.today - 2] }
      }
    end

    it 'groups failures by branch and prints them correctly' do
      expect(OssStats::Log.instance).to receive(:info).with("\n* CI Stats:")
      # Order of branches depends on hash iteration, so check both messages without .ordered for branch lines
      expect(OssStats::Log.instance).to receive(:info).with("    * Branch: `develop` has the following failures:")
      expect(OssStats::Log.instance).to receive(:info).with("        * Buildkite / org/pipe / Job X: 2 days")
      expect(OssStats::Log.instance).to receive(:info).with("    * Branch: `main` has the following failures:")
      expect(OssStats::Log.instance).to receive(:info).with("        * GH Workflow / Job A: 1 days")

      # Call the method
      print_ci_status(test_failures, {})
    end
  end
end
