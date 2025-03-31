require 'rspec'
require 'octokit'
require_relative '../src/chef_ci_status'

RSpec.describe 'chef_ci_status' do
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
    it 'sleeps for the correct amount of time based on the rate limit' do
      expect(self).to receive(:sleep).with(1.0)
      rate_limited_sleep(limit_gh_ops_per_minute: 60)
    end

    it 'does not sleep if the rate limit is not set' do
      expect(self).not_to receive(:sleep)
      rate_limited_sleep({})
    end
  end

  describe '#get_pr_and_issue_stats' do
    it 'fetches PR and issue stats from GitHub' do
      allow(client).to receive(:issues).with(
        'test_org/test_repo',
        hash_including(page: 1),
      ).and_return(
        [
          double(
            created_at: Date.today - 10,
            closed_at: Date.today - 5,
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

      expect(stats[:pr][:opened]).to eq(0)
      expect(stats[:issue][:opened]).to eq(1)
      expect(stats[:issue][:closed]).to eq(1)
    end

    it 'handles empty responses gracefully' do
      allow(client).to receive(:issues).and_return([])

      stats = get_pr_and_issue_stats(client, options)

      expect(stats[:pr][:opened]).to eq(0)
      expect(stats[:issue][:opened]).to eq(0)
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

      expect(failed_tests['main']['Test Job']).to include(Date.today - 5)
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
  end
end
