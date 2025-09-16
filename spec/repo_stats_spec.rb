require 'rspec'
require 'octokit'
require 'base64'
require_relative '../lib/oss_stats/repo_stats'
require_relative '../lib/oss_stats/config/repo_stats'
require_relative '../lib/oss_stats/log'

RSpec.describe 'repo_stats' do
  include OssStats::RepoStats

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
      OssStats::Config::RepoStats.limit_gh_ops_per_minute = nil
    end

    it 'sleeps for the correct amount of time based on the rate limit' do
      OssStats::Config::RepoStats.limit_gh_ops_per_minute = 60
      expect(self).to receive(:sleep).with(1.0)
      rate_limited_sleep
    end

    it 'does not sleep if the rate limit is not set' do
      OssStats::Config::RepoStats.limit_gh_ops_per_minute = nil
      expect(self).not_to receive(:sleep)
      rate_limited_sleep
    end

    it 'does not sleep if the rate limit is 0' do
      OssStats::Config::RepoStats.limit_gh_ops_per_minute = 0
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
        double(workflows: [
                 double(id: 1, name: 'Test Workflow', html_url: 'testurl'),
               ]),
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

      failed_tests = get_failed_tests_from_ci(client, nil, options, {})

      expect(failed_tests['main']['Test Workflow / Test Job'][:dates])
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

      failed_tests = get_failed_tests_from_ci(client, nil, options, {})

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
          expect(mock_buildkite_client).to receive(:get_pipeline)
            .with('test-buildkite-org', 'actual-pipeline-name')
            .and_return({
                          url: 'testurl',
                          slug: 'actual-pipeline-name',
                        })
          expect(mock_buildkite_client).to receive(:get_pipeline)
            .with('other-org', 'other-pipeline')
            .and_return({
                          url: 'testurl',
                          slug: 'other-pipeline',
                        })
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with(
              'test-buildkite-org',
              'actual-pipeline-name',
              Date.today - options[:days],
              Date.today,
              'main',
            )
            .and_return(
              [
                {
                  'node' => {
                    'createdAt' => (Date.today - 1).to_s, 'state' => 'FAILED'
                  },
                },
              ],
            )
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with(
              'other-org',
              'other-pipeline',
              Date.today - options[:days],
              Date.today,
              'main',
            )
            .and_return(
              [
                {
                  'node' => {
                    'createdAt' => (Date.today - 1).to_s, 'state' => 'PASSED'
                  },
                },
              ],
            )
          failed_tests = get_failed_tests_from_ci(
            client, mock_buildkite_client, settings_with_buildkite_token, {}
          )
          job1_key = '[BK] test-buildkite-org/actual-pipeline-name'
          expect(failed_tests['main'][job1_key][:dates])
            .to include(Date.today - 1)
        end

        it 'correctly parses alternative badge markdown format' do
          expect(mock_buildkite_client).to receive(:get_pipeline)
            .with('test-buildkite-org', 'another-actual-pipeline')
            .and_return({
                          url: 'testurl',
                          slug: 'another-actual-pipelinename',
                        })
          allow(client).to receive(:readme)
            .with(repo_full_name)
            .and_return(
              double(content: readme_content_with_badge_alternative_format),
            )
          expect(mock_buildkite_client).to receive(:get_pipeline_builds)
            .with(
              'test-buildkite-org',
              'another-actual-pipeline',
              Date.today - options[:days],
              Date.today,
              'main',
            )
            .and_return([])
          get_failed_tests_from_ci(
            client, mock_buildkite_client, settings_with_buildkite_token, {}
          )
        end

        it 'handles no failed builds from Buildkite' do
          expect(mock_buildkite_client).to receive(:get_pipeline)
            .with('test-buildkite-org', 'actual-pipeline-name')
            .and_return({
                          url: 'testurl',
                          slug: 'actual-pipeline-name',
                        })
          expect(mock_buildkite_client).to receive(:get_pipeline)
            .with('other-org', 'other-pipeline')
            .and_return({
                          url: 'testurl',
                          slug: 'other-pipeline',
                        })
          allow(mock_buildkite_client).to receive(:get_pipeline_builds)
            .and_return([
                          {
                            'node' => {
                              'createdAt' => (Date.today - 1).to_s,
                              'state' => 'PASSED',
                            },
                          },
                        ])
          failed_tests = get_failed_tests_from_ci(
            client, mock_buildkite_client, settings_with_buildkite_token, {}
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
          let(:org_name) { 'test-buildkite-org' }
          let(:pipeline_name) { 'actual-pipeline-name' }
          let(:job_key) { "[BK] #{org_name}/#{pipeline_name}" }

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
            expect(mock_buildkite_client).to receive(:get_pipeline)
              .with('test-buildkite-org', 'actual-pipeline-name')
              .and_return({
                            url: 'testurl',
                            slug: 'actual-pipeline-name',
                          })
            expect(mock_buildkite_client).to receive(:get_pipeline)
              .with('other-org', 'other-pipeline')
              .and_return({
                            url: 'testurl',
                            slug: 'other-pipeline',
                          })
            allow(mock_buildkite_client).to receive(:get_pipeline_builds)
              .with(
                org_name, pipeline_name, today - days_to_check, today, 'main'
              )
              .and_return(mock_builds_for_ongoing_test)

            failed_tests = get_failed_tests_from_ci(
              client, mock_buildkite_client, options_for_ongoing, {}
            )

            expected_job_dates = Set.new(
              [
                today - days_to_check + 1,
                today - days_to_check + 2,
                # no 3, it passed that day
                today - days_to_check + 4,
                # add today (days_to_check = 5), becuase we fill in
                # all days through today if the last check is failing
                today,
              ],
            )
            expect(failed_tests['main'][job_key][:dates])
              .to eq(expected_job_dates)
            expect(failed_tests['main'][job_key][:dates].size)
              .to eq(days_to_check - 1)
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
          get_failed_tests_from_ci(
            client, mock_buildkite_client, settings_with_buildkite_token, {}
          )
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
          get_failed_tests_from_ci(
            client, mock_buildkite_client, settings_with_buildkite_token, {}
          )
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
          allow(mock_buildkite_client)
            .to receive(:get_pipeline)
            .and_return({
                          url: 'testurl',
                          slug: 'actual-pipeline-name',
                        })
        end

        it 'handles the error gracefully and logs it' do
          expect(OssStats::Log).to receive(:error)
            .with(/Error during Buildkite integration for test_org/)
          failed_tests = get_failed_tests_from_ci(
            client, mock_buildkite_client, settings_with_buildkite_token, {}
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

  describe '#print_ci_status' do
    context 'with only GitHub Actions failures' do
      let(:test_failures) do
        {
          'main' => {
            'GH Workflow / Job A' => {
              dates: Set[Date.today, Date.today - 1],
              url: 'testurla',
              latest_status: 'failure',
            },
            'GH Workflow / Job B' => {
              dates: Set[Date.today],
              url: 'testurlb',
              latest_status: 'success',
            },
          },
        }
      end

      it 'prints GitHub Actions failures correctly' do
        expect(OssStats::Log).to receive(:info)
          .with("\n* CI Stats:")
        expect(OssStats::Log).to receive(:info)
          .with('    * Branch: `main` has the following failures:')
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [GH Workflow / Job A](testurla): 2 days' +
            ' (latest: failure)',
          )
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [GH Workflow / Job B](testurlb): 1 days' +
            ' (latest: success)',
          )
        print_ci_status(test_failures)
      end
    end

    context 'with only Buildkite failures' do
      let(:test_failures) do
        {
          'main' => {
            '[BK] org/pipe1' => {
              dates: Set[Date.today],
              url: 'testurl1',
              latest_status: 'failure',
            },
            '[BK] org/pipe2' => {
              dates: Set[Date.today, Date.today - 1, Date.today - 2],
              url: 'testurl2',
              latest_status: 'success',
            },
          },
        }
      end

      it 'prints Buildkite failures correctly' do
        expect(OssStats::Log).to receive(:info)
          .with("\n* CI Stats:")
        expect(OssStats::Log).to receive(:info)
          .with('    * Branch: `main` has the following failures:')
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [[BK] org/pipe1](testurl1): 1 days' +
            ' (latest: failure)',
          )
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [[BK] org/pipe2](testurl2): 3 days' +
            ' (latest: success)',
          )
        print_ci_status(test_failures)
      end
    end

    context 'with mixed GitHub Actions and Buildkite failures' do
      let(:test_failures) do
        {
          'main' => {
            'GH Workflow / Job A' => {
              dates: Set[Date.today],
              url: 'testurla',
              latest_status: 'failure',
            },
            'Buildkite / org/pipe / Job X' => {
              dates: Set[Date.today - 1],
              url: 'testurlx',
              latest_status: 'failure',
            },
            'GH Workflow / Job C' => {
              dates: Set[Date.today - 2, Date.today - 3],
              url: 'testurlc',
              latest_status: 'success',
            },
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
          .with(
            '        * [Buildkite / org/pipe / Job X](testurlx): 1 days' +
            ' (latest: failure)',
          ).ordered
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [GH Workflow / Job A](testurla): 1 days' +
            ' (latest: failure)',
          ).ordered
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [GH Workflow / Job C](testurlc): 2 days' +
            ' (latest: success)',
          ).ordered
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
          'main' => {
            'GH Workflow / Job A' => {
              dates: Set[Date.today],
              url: 'testurla',
              latest_status: 'failure',
            },
          },
          'develop' => {
            '[BK] org/pipe' => {
              dates: Set[Date.today - 1, Date.today - 2],
              url: 'testurlp',
              latest_status: 'success',
            },
          },
        }
      end

      it 'groups failures by branch and prints them correctly' do
        expect(OssStats::Log).to receive(:info)
          .with("\n* CI Stats:")
        expect(OssStats::Log).to receive(:info)
          .with('    * Branch: `main` has the following failures:')
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [GH Workflow / Job A](testurla): 1 days' +
            ' (latest: failure)',
          )
        expect(OssStats::Log).to receive(:info)
          .with('    * Branch: `develop` has the following failures:')
        expect(OssStats::Log).to receive(:info)
          .with(
            '        * [[BK] org/pipe](testurlp): 2 days' +
            ' (latest: success)',
          )

        print_ci_status(test_failures)
      end
    end
  end

  describe '#determine_orgs_to_process' do
    before(:each) do
      OssStats::Config::RepoStats.organizations(
        {
          'org1' => {
            'days' => 2,
            'repositories' => {
              'repo1' => {},
              'repo2' => {
                'days' => 3,
              },
            },
          },
          'org2' => {
            'days' => 7,
            'repositories' => {
              'repoA' => {
                'days' => 30,
              },
              'repoB' => {},
            },
          },
        },
      )
    end
    let(:config) { OssStats::Config::RepoStats }

    context 'combines org/repo limits properly' do
      it 'returns the config orgs when no limits specified' do
        ans = config.organizations.dup
        expect(determine_orgs_to_process).to eq(ans)
      end

      it 'returns only the specified org when requested' do
        ans = { 'org2' => config.organizations['org2'].dup }
        config.github_org = 'org2'
        expect(determine_orgs_to_process).to eq(ans)
      end

      it 'returns only the specified org/repo when requested' do
        ans = { 'org2' => config.organizations['org2'].dup }
        ans['org2']['repositories'].delete('repoA')
        config.github_org = 'org2'
        config.github_repo = 'repoB'
        expect(determine_orgs_to_process).to eq(ans)
      end

      it 'creates an appropriate entry when none exists' do
        ans = { 'neworg' => { 'repositories' => { 'repo' => {} } } }
        config.github_org = 'neworg'
        config.github_repo = 'repo'
        expect(determine_orgs_to_process).to eq(ans)
      end
    end
  end

  describe '#get_effective_repo_settings' do
    before(:each) do
      OssStats::Config::RepoStats.days = nil
      OssStats::Config::RepoStats.branches = nil
      OssStats::Config::RepoStats.default_days = 15
      OssStats::Config::RepoStats.default_branches = ['foo']
    end
    context 'with no org or repo overrides' do
      it 'uses defaults properly' do
        ans = {
          org: 'org1', repo: 'repo1', days: 15, branches: ['foo']
        }
        expect(get_effective_repo_settings('org1', 'repo1', {}, {})).to eq(ans)
      end

      it 'uses CLI days override properly' do
        OssStats::Config::RepoStats.days = 2
        ans = {
          org: 'org1', repo: 'repo1', days: 2, branches: ['foo']
        }
        expect(get_effective_repo_settings('org1', 'repo1', {}, {})).to eq(ans)
      end
    end

    context 'with org and repo overrides' do
      it 'overrides default with org settings' do
        s = get_effective_repo_settings(
          'org1',
          'repo1',
          { 'days' => 77 },
          {},
        )
        expect(s[:days]).to eq(77)
      end

      it 'overrides default and org with repo settings' do
        s = get_effective_repo_settings(
          'org1',
          'repo1',
          { 'days' => 77, 'branches' => ['release'] },
          { 'days' => 99 },
        )
        # days comes from repo settings
        expect(s[:days]).to eq(99)
        # most specific branches setting is from org
        expect(s[:branches]).to eq(['release'])
      end

      it 'overrides default org and repo with cli days settings' do
        OssStats::Config::RepoStats.days = 11
        s = get_effective_repo_settings(
          'org1',
          'repo1',
          { 'days' => 77, 'branches' => ['release'] },
          { 'days' => 99, 'branches' => ['special'] },
        )
        # days comes from CLI override
        expect(s[:days]).to eq(11)
        # most specific branches setting is from repo
        expect(s[:branches]).to eq(['special'])
      end

      it 'overrides default org and repo with cli branches settings' do
        OssStats::Config::RepoStats.branches = ['somebranch']
        s = get_effective_repo_settings(
          'org1',
          'repo1',
          { 'days' => 77, 'branches' => ['release'] },
          { 'days' => 99, 'branches' => ['special'] },
        )
        # days comes from CLI override
        expect(s[:days]).to eq(99)
        # most specific branches setting is from repo
        expect(s[:branches]).to eq(['somebranch'])
      end
    end
  end

  describe '#filter_repositories' do
    let(:config) { OssStats::Config::RepoStats }
    let(:all_repos) { [] } # Populated in specific contexts

    # Helper to create mock repository data for testing filter_repositories
    def mock_repo_data(
      name, stale_pr: 0, stale_issue: 0, oldest_pr_days: 0,
      oldest_issue_days: 0, avg_close_pr_hours: 0, avg_close_issue_hours: 0,
      ci_broken_days_map: {}, ci_distinct_broken_jobs: []
    )
      pr_stats = {
        stale_count: stale_pr, oldest_open_days: oldest_pr_days,
        avg_time_to_close_hours: avg_close_pr_hours, closed: 1,
        total_close_time: avg_close_pr_hours
      }
      issue_stats = {
        stale_count: stale_issue, oldest_open_days: oldest_issue_days,
        avg_time_to_close_hours: avg_close_issue_hours, closed: 1,
        total_close_time: avg_close_issue_hours
      }

      # ci_broken_days_map: { "job_name" => num_days_failed, ... }
      # ci_distinct_broken_jobs: ["job_name1", "job_name2", ...]
      ci_failures_data = nil
      if !ci_broken_days_map.empty? || !ci_distinct_broken_jobs.empty?
        ci_failures_data = { 'main' => {} }

        ci_broken_days_map.each do |job_name, days_count|
          ci_failures_data['main'][job_name] = {
            dates: Set.new((1..days_count).map { |i| Date.today - i }),
            url: "http://ci.com/#{job_name}",
          }
        end

        ci_distinct_broken_jobs.each do |job_name|
          next if ci_failures_data['main'].key?(job_name)
          ci_failures_data['main'][job_name] = {
            dates: Set[Date.today - 1],
            url: "http://ci.com/#{job_name}",
          }
        end
      end

      {
        name:,
        url: "http://github.com/org/#{name}",
        settings: { days: 30 }, # Default settings
        pr_issue_stats: {
          pr: pr_stats, issue: issue_stats,
          pr_list: { open: [], closed: [] },
          issue_list: { open: [], closed: [] }
        },
        ci_failures: ci_failures_data,
      }
    end

    after(:each) do
      config.top_n_stale = nil
      config.top_n_oldest = nil
      config.top_n_time_to_close = nil
      config.top_n_most_broken_ci_days = nil
      config.top_n_most_broken_ci_jobs = nil
      config.top_n_stale_pr = nil
      config.top_n_stale_issue = nil
      config.top_n_oldest_pr = nil
      config.top_n_oldest_issue = nil
      config.top_n_time_to_close_pr = nil
      config.top_n_time_to_close_issue = nil
    end

    before do
      config.mode = %w{pr issue ci}
    end

    context 'when no filters are set' do
      let(:repos_data) do
        [
          mock_repo_data('repo1', stale_pr: 1),
          mock_repo_data('repo2', stale_pr: 2),
        ]
      end

      it 'returns all repositories' do
        result = filter_repositories(repos_data, config).map { |r| r[:name] }
        expect(result).to match_array(%w{repo1 repo2})
      end
    end

    context 'with a single filter (absolute number)' do
      let(:repos_data) do
        [
          mock_repo_data('repo1', stale_pr: 10), # Most stale
          mock_repo_data('repo2', stale_pr: 5),  # Second most
          mock_repo_data('repo3', stale_pr: 1),
        ]
      end

      it 'returns the top N repositories for that filter' do
        config.top_n_stale = 2
        filtered = filter_repositories(repos_data, config)
        expect(filtered.map { |r| r[:name] }).to match_array(%w{repo1 repo2})
      end

      it 'returns all repositories if N is larger than the number of repos' do
        config.top_n_stale = 5
        filtered = filter_repositories(repos_data, config)
        expect(filtered.map { |r| r[:name] })
          .to match_array(%w{repo1 repo2 repo3})
      end
    end

    context 'with a single filter (percentage)' do
      let(:repos_data) do
        [
          mock_repo_data('repo1', oldest_pr_days: 100), # Oldest
          mock_repo_data('repo2', oldest_pr_days: 90),  # Second oldest
          mock_repo_data('repo3', oldest_pr_days: 80),
          mock_repo_data('repo4', oldest_pr_days: 70),
        ]
      end

      it 'returns the top N% repositories (even count)' do
        config.top_n_oldest = 0.5 # 50%
        filtered = filter_repositories(repos_data, config)
        # 50% of 4 is 2. Expect repo1, repo2
        expect(filtered.map { |r| r[:name] }).to match_array(%w{repo1 repo2})
      end

      it 'returns the top N% repositories (odd count, ceil)' do
        three_repos = repos_data[0..2] # repo1, repo2, repo3
        config.top_n_oldest = 0.5 # 50%
        filtered = filter_repositories(three_repos, config)
        # 50% of 3 is 1.5, ceil(1.5) is 2. Expect repo1, repo2
        expect(filtered.map { |r| r[:name] }).to match_array(%w{repo1 repo2})
      end
    end

    context 'with multiple filters' do
      let(:repos_data) do
        [
          # High stale, low CI
          mock_repo_data(
            'repoA', stale_pr: 10, ci_broken_days_map: { 'job1' => 1 }
          ),
          # Low stale, high CI
          mock_repo_data(
            'repoB', stale_pr: 1, ci_broken_days_map: { 'job1' => 10 }
          ),
          # Medium for both
          mock_repo_data(
            'repoC', stale_pr: 2, ci_broken_days_map: { 'job1' => 2 }
          ),
          # Low for both
          mock_repo_data('repoD', stale_pr: 0, ci_broken_days_map: {}),
        ]
      end

      it 'returns repositories meeting any condition without duplicates' do
        # Expect repoA
        config.top_n_stale = 1
        # Expect repoB
        config.top_n_most_broken_ci_days = 1

        filtered = filter_repositories(repos_data, config)
        expect(filtered.map { |r| r[:name] }).to match_array(%w{repoA repoB})
      end
    end

    context 'with all filters active' do
      let(:repos_data) do
        [
          mock_repo_data('r_stale', stale_pr: 100),
          mock_repo_data('r_oldest', oldest_issue_days: 100),
          mock_repo_data('r_ttc', avg_close_pr_hours: 100),
          mock_repo_data('r_ci_days',
ci_broken_days_map: { 'main_job' => 100 }),
          mock_repo_data(
            'r_ci_jobs',
            ci_distinct_broken_jobs: %w{j1 j2 j3 j4 j5},
          ),
          mock_repo_data(
            'r_all_low',
            stale_pr: 1,
            oldest_issue_days: 1,
            avg_close_pr_hours: 1,
            ci_broken_days_map: { 'mj' => 1 },
            ci_distinct_broken_jobs: ['j'],
          ),
        ]
      end

      it 'returns repositories meeting any of the criteria' do
        # r_stale
        config.top_n_stale = 1
        # r_oldest
        config.top_n_oldest = 1
        # r_ttc
        config.top_n_time_to_close = 1
        # r_ci_days
        config.top_n_most_broken_ci_days = 1
        # r_ci_jobs
        config.top_n_most_broken_ci_jobs = 1

        filtered = filter_repositories(repos_data, config)
        expect(filtered.map { |r| r[:name] })
          .to match_array(%w{r_stale r_oldest r_ttc r_ci_days r_ci_jobs})
      end
    end

    context 'edge cases' do
      it 'returns an empty list if no repositories meet criteria' do
        repos = [mock_repo_data('repo1', stale_pr: 0)]
        config.top_n_stale = 1
        expect(filter_repositories(repos, config)).to be_empty
      end

      it 'returns an empty list if input is empty' do
        expect(filter_repositories([], config)).to be_empty
      end
    end

    context 'data integrity' do
      it 'returned repositories retain their original data structure' do
        repo = mock_repo_data('integrity_test', stale_pr: 10)
        config.top_n_stale = 1
        filtered = filter_repositories([repo], config)
        expect(filtered.first).to eq(repo)
        expect(filtered.first[:pr_issue_stats][:pr][:stale_count]).to eq(10)
      end
    end

    context 'specific filter logic: top_n_stale' do
      let(:repos_data) do
        [
          mock_repo_data(
            'repo_pr_high_issue_low', stale_pr: 10, stale_issue: 1
          ),
          mock_repo_data(
            'repo_pr_low_issue_high', stale_pr: 1, stale_issue: 12
          ),
          mock_repo_data('repo_both_mid', stale_pr: 5, stale_issue: 5),
          mock_repo_data('repo_both_low', stale_pr: 1, stale_issue: 1),
        ]
      end
      it 'selects based on MAX of stale PRs or Issues' do
        # Expect repo_pr_low_issue_high (12), repo_pr_high_issue_low (10)
        config.top_n_stale = 2
        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names)
          .to match_array(%w{repo_pr_low_issue_high repo_pr_high_issue_low})
      end
    end

    context 'specific filter logic: top_n_oldest' do
      let(:repos_data) do
        [
          mock_repo_data(
            'repo_pr_old', oldest_pr_days: 100, oldest_issue_days: 10
          ),
          mock_repo_data(
            'repo_issue_old', oldest_pr_days: 10, oldest_issue_days: 100
          ),
          mock_repo_data(
            'repo_both_young', oldest_pr_days: 5, oldest_issue_days: 5
          ),
        ]
      end
      it 'selects based on max of oldest PR or Issue' do
        config.top_n_oldest = 2 # Expect repo_pr_old, repo_issue_old
        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names).to match_array(%w{repo_pr_old repo_issue_old})
      end
    end

    context 'specific filter logic: top_n_time_to_close' do
      let(:repos_data) do
        [
          mock_repo_data(
            'repo_pr_slow', avg_close_pr_hours: 100, avg_close_issue_hours: 10
          ),
          mock_repo_data(
            'repo_issue_slow', avg_close_pr_hours: 10,
                               avg_close_issue_hours: 100
          ),
          mock_repo_data(
            'repo_both_fast', avg_close_pr_hours: 5, avg_close_issue_hours: 5
          ),
        ]
      end
      it 'selects based on max of PR or Issue avg time to close' do
        # Expect repo_pr_slow, repo_issue_slow
        config.top_n_time_to_close = 2
        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names).to match_array(%w{repo_pr_slow repo_issue_slow})
      end
    end

    context 'specific filter logic: top_n_most_broken_ci_days' do
      let(:repos_data) do
        [
          mock_repo_data(
            'ci_heavy_broken', ci_broken_days_map: { 'jobA' => 10, 'jobB' => 5 }
          ),
          mock_repo_data('ci_light_broken',
ci_broken_days_map: { 'jobA' => 1 }),
          mock_repo_data(
            'ci_medium_broken', ci_broken_days_map: { 'jobA' => 3, 'jobB' => 3 }
          ),
        ]
      end
      it 'selects based on total broken days across all jobs' do
        # Expect ci_heavy_broken, ci_medium_broken
        config.top_n_most_broken_ci_days = 2
        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names)
          .to match_array(%w{ci_heavy_broken ci_medium_broken})
      end
    end

    context 'specific filter logic: top_n_most_broken_ci_jobs' do
      let(:repos_data) do
        [
          mock_repo_data(
            'ci_many_jobs', ci_distinct_broken_jobs: %w{j1 j2 j3}
          ),
          mock_repo_data(
            'ci_few_jobs', ci_distinct_broken_jobs: ['j1']
          ),
          mock_repo_data(
            'ci_moderate_jobs', ci_distinct_broken_jobs: %w{j1 j2}
          ),
        ]
      end
      it 'selects based on number of distinct broken jobs' do
        # Expect ci_many_jobs, ci_moderate_jobs
        config.top_n_most_broken_ci_jobs = 2
        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names).to match_array(%w{ci_many_jobs ci_moderate_jobs})
      end
    end

    context 'with missing stats sections' do
      let(:repo_no_ci) { mock_repo_data('no_ci_stats', stale_pr: 5) }
      let(:repo_no_pr_issue) do
        mock_repo_data('no_pr_issue_stats', ci_broken_days_map: { 'j1' => 5 })
      end

      before do
        # Simulate missing sections more accurately
        repo_no_ci[:ci_failures] = nil
        repo_no_pr_issue[:pr_issue_stats] = nil
      end

      let(:repos_data) do
        [
          repo_no_ci,
          repo_no_pr_issue,
          mock_repo_data(
            'full_stats', stale_pr: 10, ci_broken_days_map: { 'j1' => 10 }
          ),
        ]
      end

      it 'handles missing ci_failures for CI filters' do
        # Expect 'full_stats' (10 days), then 'no_pr_issue_stats' (5 days).
        # 'no_ci_stats' effectively has 0.
        config.top_n_most_broken_ci_days = 1
        filtered = filter_repositories(repos_data, config)
        expect(filtered.map { |r| r[:name] }).to eq(['full_stats'])
      end

      it 'handles missing pr_issue_stats for PR/issue filters' do
        # Expect 'full_stats' (10 stale), then 'no_ci_stats' (5 stale).
        # 'no_pr_issue_stats' effectively has 0.
        config.top_n_stale = 1
        filtered = filter_repositories(repos_data, config)
        expect(filtered.map { |r| r[:name] }).to eq(['full_stats'])
      end
    end

    context 'specific filter logic: top_n_stale_pr' do
      let(:repos_data) do
        [
          mock_repo_data('r1', stale_pr: 10),
          mock_repo_data('r2', stale_pr: 5),
          mock_repo_data('r3', stale_pr: 12),
        ]
      end
      it 'selects based on PR stale count only' do
        config.top_n_stale_pr = 2
        expect(filter_repositories(repos_data, config)
          .map { |r| r[:name] }).to match_array(%w{r3 r1})
      end
    end

    context 'specific filter logic: top_n_oldest_pr' do
      let(:repos_data) do
        [
          mock_repo_data('r1', oldest_pr_days: 100),
          mock_repo_data('r2', oldest_pr_days: 50),
          mock_repo_data('r3', oldest_pr_days: 120),
        ]
      end
      it 'selects based on PR oldest open days only' do
        config.top_n_oldest_pr = 2
        expect(filter_repositories(repos_data, config)
          .map { |r| r[:name] }).to match_array(%w{r3 r1})
      end
    end

    context 'specific filter logic: top_n_time_to_close_pr' do
      let(:repos_data) do
        [
          mock_repo_data('r1', avg_close_pr_hours: 100),
          mock_repo_data('r2', avg_close_pr_hours: 50),
          mock_repo_data('r3', avg_close_pr_hours: 120),
        ]
      end
      it 'selects based on PR avg time to close only' do
        config.top_n_time_to_close_pr = 2
        expect(filter_repositories(repos_data, config)
          .map { |r| r[:name] }).to match_array(%w{r3 r1})
      end
    end

    context 'specific filter logic: top_n_stale_issue' do
      let(:repos_data) do
        [
          mock_repo_data('r1', stale_issue: 10),
          mock_repo_data('r2', stale_issue: 5),
          mock_repo_data('r3', stale_issue: 12),
        ]
      end

      it 'selects based on Issue stale count only' do
        config.top_n_stale_issue = 2
        expect(filter_repositories(repos_data, config)
          .map { |r| r[:name] }).to match_array(%w{r3 r1})
      end
    end

    context 'specific filter logic: top_n_oldest_issue' do
      let(:repos_data) do
        [
          mock_repo_data('r1', oldest_issue_days: 100),
          mock_repo_data('r2', oldest_issue_days: 50),
          mock_repo_data('r3', oldest_issue_days: 120),
        ]
      end

      it 'selects based on Issue oldest open days only' do
        config.top_n_oldest_issue = 2
        expect(filter_repositories(repos_data, config)
          .map { |r| r[:name] }).to match_array(%w{r3 r1})
      end
    end

    context 'specific filter logic: top_n_time_to_close_issue' do
      let(:repos_data) do
        [
          mock_repo_data('r1', avg_close_issue_hours: 100),
          mock_repo_data('r2', avg_close_issue_hours: 50),
          mock_repo_data('r3', avg_close_issue_hours: 120),
        ]
      end
      it 'selects based on Issue avg time to close only' do
        config.top_n_time_to_close_issue = 2
        expect(filter_repositories(repos_data, config)
          .map { |r| r[:name] }).to match_array(%w{r3 r1})
      end
    end

    context 'with combinations of general and specific PR/Issue filters' do
      let(:repos_data) do
        [
          # Max stale = 20 (Issue)
          mock_repo_data('repo_max_stale_high', stale_pr: 1, stale_issue: 20),
          # PR stale = 15
          mock_repo_data('repo_pr_stale_high', stale_pr: 15, stale_issue: 1),
          # Issue stale = 18
          mock_repo_data('repo_issue_stale_high', stale_pr: 2, stale_issue: 18),
          mock_repo_data('repo_all_low', stale_pr: 1, stale_issue: 1),
        ]
      end

      it 'includes repos meeting general OR specific criteria ' +
         '(top_n_stale and top_n_stale_pr)' do
        # Expect repo_max_stale_high (20)
        config.top_n_stale = 1
        # Expect repo_pr_stale_high (15)
        config.top_n_stale_pr = 1

        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names)
          .to match_array(%w{repo_max_stale_high repo_pr_stale_high})
      end

      it 'includes repos meeting general OR specific criteria ' +
         '(top_n_stale and top_n_stale_issue)' do
        # Expect repo_max_stale_high (20)
        config.top_n_stale = 1
        # top issues count is the same
        config.top_n_stale_issue = 1

        filtered_names = filter_repositories(repos_data, config)
                         .map { |r| r[:name] }
        expect(filtered_names).to match_array(%w{repo_max_stale_high})
      end
    end
  end
end
