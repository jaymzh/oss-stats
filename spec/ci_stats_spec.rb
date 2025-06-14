require 'rspec'
require 'octokit'
require_relative '../src/ci_stats'
require_relative '../src/lib/oss_stats/ci_stats_config'
# Added for Buildkite
require_relative '../src/lib/oss_stats/buildkite_client'
require_relative '../src/lib/oss_stats/buildkite_token'

RSpec.describe 'ci_status' do
  let(:client) { instance_double(Octokit::Client) }
  let(:options) do
    {
      org: 'test_org',
      repo: 'test_repo',
      days: 30,
      branches: ['main']
    }
  end

  before do
    allow(client).to receive(:issues).and_return([])
    allow(client).to receive(:pull_requests).and_return([])
    allow(client).to receive(:workflows).and_return(double(workflows: []))
    allow(client).to receive(:workflow_runs)
      .and_return(double(workflow_runs: []))
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
      allow(client).to receive(:issues)
        .with('test_org/test_repo', hash_including(page: 1))
        .and_return([
          # closed PR
          double(
            created_at: Date.today - 7,
            closed_at: Date.today - 5,
            pull_request: double(merged_at: Date.today - 5),
            updated_at: Date.today - 3,
            labels: []
          ),
          # open Issue
          double(
            created_at: Date.today - 7,
            closed_at: nil,
            pull_request: nil,
            updated_at: Date.today - 3,
            labels: []
          )
        ])
      allow(client).to receive(:issues)
        .with('test_org/test_repo', hash_including(page: 2))
        .and_return([])

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
    let(:mock_buildkite_client) do
      instance_double(OssStats::BuildkiteClient)
    end
    let(:readme_content_with_badge) do
      "Some text before\n" \
      "[![Build Status]" \
      "(https://badge.buildkite.com/test-org/test-pipeline.svg)]" \
      "(https://buildkite.com/test-org/test-pipeline)\n" \
      "Some text after"
    end
    let(:readme_content_without_badge) do
      "This README has no Buildkite badge."
    end

    before do
      # Common stubs for Buildkite integration
      allow(OssStats::BuildkiteToken).to receive(:token).with('test-org')
                                                        .and_return('fake-bk-token')
      allow(OssStats::BuildkiteClient).to receive(:new)
        .with('fake-bk-token', 'test-org')
        .and_return(mock_buildkite_client)
      allow(client).to receive(:readme)
        .with('test_org/test_repo', accept: 'application/vnd.github.v3.raw')
        .and_return(readme_content_with_badge)
      # Default to no failures for Buildkite
      allow(mock_buildkite_client).to receive(:get_pipeline_builds)
        .and_return([])
    end

    context 'GitHub Actions' do
      it 'fetches failed tests from CI workflows' do
        # No BK for this test
        allow(client).to receive(:readme)
          .with('test_org/test_repo', accept: 'application/vnd.github.v3.raw')
          .and_return(readme_content_without_badge)
        allow(client).to receive(:workflows)
          .and_return(double(workflows: [double(id: 1, name: 'Test Workflow')]))
        allow(client).to receive(:workflow_runs)
          .with('test_org/test_repo', 1, hash_including(page: 1))
          .and_return(double(workflow_runs: [
            double(id: 1, created_at: Date.today - 5)
          ]))
        allow(client).to receive(:workflow_runs)
          .with('test_org/test_repo', 1, hash_including(page: 2))
          .and_return(double(workflow_runs: []))
        allow(client).to receive(:workflow_run_jobs)
          .and_return(double(jobs: [
            double(name: 'Test Job', conclusion: 'failure')
          ]))

        failed_tests = get_failed_tests_from_ci(client, options)
        job_key = '[GitHub Actions] Test Workflow / Test Job'
        expect(failed_tests['main'][job_key]).to include(Date.today - 5)
      end
    end

    context 'Buildkite Integration' do
      it 'includes Buildkite failures when badge found and builds failed' do
        failed_bk_job = {
          name: "Buildkite Job A",
          date: (Date.today - 3).strftime('%Y-%m-%d')
        }
        allow(mock_buildkite_client).to receive(:get_pipeline_builds)
          .with('test-pipeline', 'main', Date.today - options[:days])
          .and_return([failed_bk_job])

        # Ensure GitHub Actions part doesn't find anything
        allow(client).to receive(:workflows).and_return(double(workflows: []))

        failed_tests = get_failed_tests_from_ci(client, options)
        bk_job_key = "[Buildkite] test-org/test-pipeline / Buildkite Job A"
        expect(failed_tests['main']).to include(bk_job_key)
        expect(failed_tests['main'][bk_job_key]).to include(Date.today - 3)
      end

      it 'does not add Buildkite failures if pipeline has no failures' do
        allow(mock_buildkite_client).to receive(:get_pipeline_builds)
          .and_return([])
        # No GH failures
        allow(client).to receive(:workflows).and_return(double(workflows: []))

        failed_tests = get_failed_tests_from_ci(client, options)
        has_bk_failures = failed_tests['main'].keys.any? do |k|
          k.start_with?('[Buildkite]')
        end
        expect(has_bk_failures).to be_falsey
      end

      it 'does not attempt to fetch Buildkite stats if no badge is found' do
        allow(client).to receive(:readme)
          .with('test_org/test_repo', accept: 'application/vnd.github.v3.raw')
          .and_return(readme_content_without_badge)
        expect(OssStats::BuildkiteClient).not_to receive(:new)
        # No GH failures
        allow(client).to receive(:workflows).and_return(double(workflows: []))

        failed_tests = get_failed_tests_from_ci(client, options)
        expect(failed_tests['main']).to be_empty
      end

      it 'handles README not found gracefully for Buildkite' do
        allow(client).to receive(:readme)
          .with('test_org/test_repo', accept: 'application/vnd.github.v3.raw')
          .and_raise(Octokit::NotFound)
        expect(OssStats::BuildkiteClient).not_to receive(:new)
        # No GH failures
        allow(client).to receive(:workflows).and_return(double(workflows: []))

        log_msg = /README.md not found for test_org\/test_repo/
        expect(OssStats::Log.instance).to receive(:warn).with(log_msg)
        failed_tests = get_failed_tests_from_ci(client, options)
        expect(failed_tests['main']).to be_empty
      end

      it 'warns and skips Buildkite if token is not found' do
        allow(OssStats::BuildkiteToken).to receive(:token).with('test-org')
                                                        .and_return(nil)
        expect(OssStats::BuildkiteClient).not_to receive(:new)
        # No GH failures
        allow(client).to receive(:workflows).and_return(double(workflows: []))

        log_msg = /Buildkite token not found for organization test-org/
        expect(OssStats::Log.instance).to receive(:warn).with(log_msg)
        failed_tests = get_failed_tests_from_ci(client, options)
        expect(failed_tests['main']).to be_empty
      end
    end

    it 'handles no GH failures gracefully' do
      allow(client).to receive(:workflows)
        .and_return(double(workflows: [double(id: 1, name: 'Test Workflow')]))
      allow(client).to receive(:workflow_runs)
        .and_return(double(workflow_runs: [])) # No runs means no failures

      # Ensure Buildkite part doesn't run for this specific GH test
      allow(client).to receive(:readme)
        .with('test_org/test_repo', accept: 'application/vnd.github.v3.raw')
        .and_return(readme_content_without_badge)

      failed_tests = get_failed_tests_from_ci(client, options)
      expect(failed_tests['main']).to be_empty
    end
  end
end
