require 'rspec'
require 'octokit'
require 'base64'
require_relative '../src/ci_stats'
require_relative '../src/lib/oss_stats/ci_stats_config'
require_relative '../src/lib/oss_stats/log'

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
      allow(client).to receive(:readme).with('test_org/test_repo')
                                       .and_return(double(content: ''))
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
      allow(client).to receive(:readme).with('test_org/test_repo')
                                       .and_return(double(content: ''))
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
        badge1 = 'https://badge.buildkite.com/someuuid.svg?branch=main'
        url1 = 'https://buildkite.com/test-buildkite-org/actual-pipeline-name'
        badge2 = 'https://badge.buildkite.com/another.svg'
        url2 = 'https://buildkite.com/other-org/other-pipeline'
        Base64.encode64(
          <<~README,
          Some text before
          [![Build Status](#{badge1})](#{url1})
          More text [![Another Badge](#{badge2})](#{url2})
          Some text after
          README
        )
      end
      let(:readme_content_with_badge_alternative_format) do
        # Test with a slightly different markdown image link format
        badge = 'https://badge.buildkite.com/short-uuid.svg'
        url = 'https://buildkite.com/test-buildkite-org/another-actual-pipeline'
        Base64.encode64(
          <<~README,
          [![] (#{badge})](#{url})
          README
        )
      end
      let(:readme_content_without_badge) do
        Base64.encode64('This README has no Buildkite badge, only text.')
      end
      let(:settings_with_buildkite_token) do
        options.merge(buildkite_token: 'fake-bk-token')
      end

      before do
        allow(self).to receive(:get_buildkite_token!)
          .with(OssStats::CiStatsConfig).and_return('fake-bk-token')
        allow(OssStats::BuildkiteClient).to receive(:new)
          .and_return(mock_buildkite_client)
        allow(mock_buildkite_client).to receive(:get_pipeline_builds)
          .and_return([])
      end

      context 'when repository has a Buildkite badge in README' do
        let(:readme_double) { double(content: readme_content_with_badge) }
        let(:repo_full_name) { "#{options[:org]}/#{options[:repo]}" }

        before do
          allow(client).to receive(:readme)
            .with(repo_full_name)
            .and_return(readme_double)
        end

        it 'calls BuildkiteClient with correct slugs and processes results' do
          expect(OssStats::BuildkiteClient).to receive(:new)
            .with('fake-bk-token', 'test-buildkite-org')
            .and_return(mock_buildkite_client)
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with(
              'actual-pipeline-name',
              nil,
              Date.today - options[:days],
              Date.today,
            )
            .and_return([
              {
                'node' => {
                  'createdAt' => (Date.today - 1).to_s, 'state' => 'FAILED'
                },
              },
            ])
          failed_tests = get_failed_tests_from_ci(
            client, settings_with_buildkite_token
          )
          job1_key = '[BK] test-buildkite-org/actual-pipeline-name'
          expect(failed_tests['main'][job1_key]).to include(Date.today - 1)
        end

        it 'correctly parses alternative badge markdown format' do
          allow(client).to receive(:readme)
            .with(repo_full_name)
            .and_return(
              double(content: readme_content_with_badge_alternative_format),
            )
          expect(OssStats::BuildkiteClient).to receive(:new)
            .with('fake-bk-token', 'test-buildkite-org')
            .and_return(mock_buildkite_client)
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with(
              'another-actual-pipeline',
              nil,
              Date.today - options[:days],
              Date.today,
            )
            .and_return([])
          get_failed_tests_from_ci(client, settings_with_buildkite_token)
        end

        it 'handles no failed builds from Buildkite' do
          allow(mock_buildkite_client).to receive(:get_pipeline_builds)
            .and_return([
              {
                'node' => {
                  'createdAt' => (Date.today - 1).to_s,
                  'state' => 'PASSED',
                  'jobs' => {
                    'edges' => [
                      {
                        'node' => {
                          'label' => 'Test Job 1', 'state' => 'PASSED'
                        },
                      },
                    ],
                  },
                },
              },
            ])
          failed_tests = get_failed_tests_from_ci(
            client, settings_with_buildkite_token
          )
          buildkite_job_keys = failed_tests['main'].keys.select do |k|
            k.start_with?('Buildkite /')
          end
          expect(buildkite_job_keys).to be_empty
        end

        context 'with ongoing failures' do
          let(:days_to_check) { 5 }
          let(:options_for_ongoing) { options.merge(days: days_to_check) }
          let(:today) { Date.today }
          let(:pipeline_name) { 'actual-pipeline-name' }
          let(:job_key) { "[BK] test-buildkite-org/#{pipeline_name}" }

          let(:mock_builds_for_ongoing_test) do
            # Helper to create a build node
            def build_node(created_at_val, state_val)
              {
                'node' => {
                  'createdAt' => created_at_val.to_s,
                  'state' => state_val,
                },
              }
            end

            [
              build_node(today - days_to_check + 1, 'FAILED'),
              build_node(today - days_to_check + 2, 'FAILED'),
              build_node(today - days_to_check + 3, 'PASSED'),
              build_node(today - days_to_check + 4, 'FAILED'),
            ].sort_by { |b| DateTime.parse(b['node']['createdAt']) }
          end

          it 'correctly reports days for ongoing and fixed failures' do
            allow(mock_buildkite_client).to receive(:get_pipeline_builds)
              .with(pipeline_name, nil, today - days_to_check, today)
              .and_return(mock_builds_for_ongoing_test)

            failed_tests = get_failed_tests_from_ci(client, options_for_ongoing)

            expected_job_dates = Set.new([
              today - days_to_check + 1,
              today - days_to_check + 2,
              # no 3, it passed that day
              today - days_to_check + 4,
              # add today (days_to_check = 5), becuase we fill in
              # all days through today if the last check is failing
              today,
            ])
            expect(failed_tests['main'][job_key]).to eq(expected_job_dates)
            expect(failed_tests['main'][job_key].size).to eq(days_to_check - 1)
          end
        end
      end

      context 'when repository does not have a Buildkite badge' do
        before do
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}")
            .and_return(double(content: readme_content_without_badge))
        end

        it 'does not call BuildkiteClient' do
          expect(OssStats::BuildkiteClient).not_to receive(:new)
          expect(mock_buildkite_client).not_to receive(:get_pipeline_builds)
          get_failed_tests_from_ci(client, settings_with_buildkite_token)
        end
      end

      context 'when README is not found' do
        it 'handles the error and does not call BuildkiteClient' do
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}")
            .and_raise(Octokit::NotFound)
          expect(OssStats::BuildkiteClient).not_to receive(:new)
          expect(OssStats::Log).to receive(:warn)
            .with(%r{README.md not found for repo test_org/test_repo})
          get_failed_tests_from_ci(client, settings_with_buildkite_token)
        end
      end

      context 'when Buildkite API call fails' do
        before do
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}")
            .and_return(double(content: readme_content_with_badge))
          allow(mock_buildkite_client)
            .to receive(:get_pipeline_builds)
            .and_raise(StandardError.new('Buildkite API Error'))
        end

        it 'handles the error gracefully and logs it' do
          expect(OssStats::Log).to receive(:error)
            .with(/Error during Buildkite integration for test_org/)
          failed_tests = get_failed_tests_from_ci(
            client, settings_with_buildkite_token
          )
          buildkite_job_keys = failed_tests['main'].keys.select do |k|
            k.start_with?('Buildkite /')
          end
          expect(buildkite_job_keys).to be_empty
        end
      end

      context 'when Buildkite token is not available' do
        before do
          # Mock get_buildkite_token! to return nil
          allow(self).to receive(:get_buildkite_token!)
            .and_raise(ArgumentError)
          allow(client).to receive(:readme)
            .with("#{options[:org]}/#{options[:repo]}")
            .and_return(double(content: readme_content_with_badge))
        end
      end
    end
  end
end

describe '#print_ci_status' do
  context 'with only GitHub Actions failures' do
    let(:test_failures) do
      {
        'main' => {
          'GH Workflow / Job A' => Set[Date.today, Date.today - 1],
          'GH Workflow / Job B' => Set[Date.today],
        },
      }
    end

    it 'prints GitHub Actions failures correctly' do
      expect(OssStats::Log).to receive(:info)
        .with("\n* CI Stats:")
      expect(OssStats::Log).to receive(:info)
        .with('    * Branch: `main` has the following failures:')
      expect(OssStats::Log).to receive(:info)
        .with('        * GH Workflow / Job A: 2 days')
      expect(OssStats::Log).to receive(:info)
        .with('        * GH Workflow / Job B: 1 days')
      print_ci_status(test_failures)
    end
  end

  context 'with only Buildkite failures' do
    let(:test_failures) do
      {
        'main' => {
          '[BK] org/pipe1' => Set[Date.today],
          '[BK] org/pipe2' => Set[Date.today, Date.today - 1, Date.today - 2],
        },
      }
    end

    it 'prints Buildkite failures correctly' do
      expect(OssStats::Log).to receive(:info)
        .with("\n* CI Stats:")
      expect(OssStats::Log).to receive(:info)
        .with('    * Branch: `main` has the following failures:')
      expect(OssStats::Log).to receive(:info)
        .with('        * [BK] org/pipe1: 1 days')
      expect(OssStats::Log).to receive(:info)
        .with('        * [BK] org/pipe2: 3 days')
      print_ci_status(test_failures)
    end
  end

  context 'with mixed GitHub Actions and Buildkite failures' do
    let(:test_failures) do
      {
        'main' => {
          'GH Workflow / Job A' => Set[Date.today],
          'Buildkite / org/pipe / Job X' => Set[Date.today - 1],
          'GH Workflow / Job C' => Set[Date.today - 2, Date.today - 3],
        },
      }
    end

    it 'prints mixed failures correctly and sorted' do
      expect(OssStats::Log).to receive(:info)
        .with("\n* CI Stats:")
      expect(OssStats::Log).to receive(:info)
        .with('    * Branch: `main` has the following failures:')
      # Sorted order: Buildkite job first, then GH jobs
      expect(OssStats::Log).to receive(:info)
        .with('        * Buildkite / org/pipe / Job X: 1 days').ordered
      expect(OssStats::Log).to receive(:info)
        .with('        * GH Workflow / Job A: 1 days').ordered
      expect(OssStats::Log).to receive(:info)
        .with('        * GH Workflow / Job C: 2 days').ordered
      print_ci_status(test_failures)
    end
  end

  context 'with no failures' do
    let(:test_failures) { { 'main' => {} } }

    it 'prints the no failures message' do
      expect(OssStats::Log).to receive(:info)
        .with("\n* CI Stats:")
      expect(OssStats::Log).to receive(:info)
        .with('    * Branch: `main`: No job failures found! :tada:')
      print_ci_status(test_failures)
    end
  end

  context 'with failures on multiple branches' do
    let(:test_failures) do
      {
        'main' => { 'GH Workflow / Job A' => Set[Date.today] },
        'develop' => { '[BK] org/pipe' => Set[Date.today - 1, Date.today - 2] },
      }
    end

    it 'groups failures by branch and prints them correctly' do
      expect(OssStats::Log).to receive(:info)
        .with("\n* CI Stats:")
      expect(OssStats::Log).to receive(:info)
        .with('    * Branch: `develop` has the following failures:')
      expect(OssStats::Log).to receive(:info)
        .with('        * [BK] org/pipe: 2 days')
      expect(OssStats::Log).to receive(:info)
        .with('    * Branch: `main` has the following failures:')
      expect(OssStats::Log).to receive(:info)
        .with('        * GH Workflow / Job A: 1 days')

      print_ci_status(test_failures)
    end
  end
end
