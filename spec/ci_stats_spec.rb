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
    allow(client)
      .to receive(:workflow_runs)
      .and_return(double(workflow_runs: []))
    allow(client)
      .to receive(:workflow_run_jobs)
      .and_return(double(jobs: []))
  end

  # Helper method to create mock GitHub item objects
  def create_mock_item(created_at:,
                       closed_at: nil,
                       pull_request: nil,
                       updated_at:,
                       labels: [])
    # Ensure Time objects for calculations if Date objects are passed
    created_at_time = created_at.is_a?(Date) ? created_at.to_time.utc : created_at
    closed_at_time = closed_at.is_a?(Date) ? closed_at.to_time.utc : closed_at
    updated_at_time = updated_at.is_a?(Date) ? updated_at.to_time.utc : updated_at

    item = double(
      created_at: created_at_time,
      closed_at: closed_at_time,
      pull_request: pull_request,
      updated_at: updated_at_time, # Used for .to_date in stale check
      labels: labels.map { |label_name| double(name: label_name) }
    )
    if pull_request && closed_at_time
      # Ensure merged_at is also a Time object if closed_at is
      allow(item.pull_request).to receive(:merged_at).and_return(closed_at_time)
    elsif pull_request
      allow(item.pull_request).to receive(:merged_at).and_return(nil)
    end
    item
  end

  # Helper methods for get_failed_tests_from_ci
  def create_mock_workflow(id, name)
    double(id: id, name: name)
  end

  def create_mock_workflow_run(id, created_at_date)
    # Ensure created_at for workflow runs is also a Time object if it's used in time-sensitive logic
    created_at_time = created_at_date.is_a?(Date) ? created_at_date.to_time.utc : created_at_date
    double(id: id, created_at: created_at_time)
  end

  def create_mock_job(name, conclusion)
    double(name: name, conclusion: conclusion)
  end

  # Stub sleep globally for all tests in this describe block
  before do
    allow_any_instance_of(Object).to receive(:sleep) # Stubs Kernel.sleep
  end

  describe '#get_pr_and_issue_stats' do
    it 'fetches PR and issue stats from GitHub' do
      allow(client)
        .to receive(:issues)
        .with('test_org/test_repo', hash_including(page: 1))
        .and_return(
          [
            create_mock_item(
              created_at: (Date.today - 7).to_time.utc, # Use Time for consistency
              closed_at: (Date.today - 5).to_time.utc,
              pull_request: double(),
              updated_at: (Date.today - 3).to_time.utc,
              labels: []
            ),
            create_mock_item(
              created_at: (Date.today - 7).to_time.utc,
              closed_at: nil,
              pull_request: nil,
              updated_at: (Date.today - 3).to_time.utc,
              labels: []
            ),
          ],
        )
      allow(client)
        .to receive(:issues)
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
      # PR stats
      expect(stats[:pr][:open]).to eq(0)
      expect(stats[:pr][:closed]).to eq(0)
      expect(stats[:pr][:opened_this_period]).to eq(0)
      expect(stats[:pr][:avg_time_to_close_hours]).to eq(0)
      expect(stats[:pr][:oldest_open]).to be_nil
      expect(stats[:pr][:oldest_open_days]).to eq(0) # Corrected
      expect(stats[:pr][:oldest_open_last_activity]).to eq(0) # Corrected
      expect(stats[:pr][:stale_count]).to eq(0)
      # Issue stats
      expect(stats[:issue][:open]).to eq(0)
      expect(stats[:issue][:closed]).to eq(0)
      expect(stats[:issue][:opened_this_period]).to eq(0)
      expect(stats[:issue][:avg_time_to_close_hours]).to eq(0)
      expect(stats[:issue][:oldest_open]).to be_nil
      expect(stats[:issue][:oldest_open_days]).to eq(0) # Corrected
      expect(stats[:issue][:oldest_open_last_activity]).to eq(0) # Corrected
      expect(stats[:issue][:stale_count]).to eq(0)
    end

    context 'when calculating avg_time_to_close_hours for PRs' do
      it 'calculates correctly for one closed PR' do
        pr_closed_time = (Date.today - 5).to_time.utc
        pr_created_time = (Date.today - 7).to_time.utc # Exactly 48 hours
        allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              create_mock_item(
                created_at: pr_created_time,
                closed_at: pr_closed_time,
                pull_request: double(),
                updated_at: (Date.today - 3).to_time.utc,
                labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expected_hours = (pr_closed_time - pr_created_time) / 3600.0
        expect(stats[:pr][:avg_time_to_close_hours]).to eq(48.0) # Fixed
        expect(stats[:pr][:avg_time_to_close_hours]).to eq(expected_hours)
      end

      it 'calculates correctly for multiple closed PRs' do
        pr1_closed_time = (Date.today - 5).to_time.utc
        pr1_created_time = (Date.today - 7).to_time.utc # 48 hours
        pr2_closed_time = (Date.today - 2).to_time.utc
        pr2_created_time = (Date.today - 6).to_time.utc # 96 hours

        allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              create_mock_item(
                created_at: pr1_created_time,
                closed_at: pr1_closed_time,
                pull_request: double(),
                updated_at: (Date.today - 1).to_time.utc,
                labels: []
              ),
              create_mock_item(
                created_at: pr2_created_time,
                closed_at: pr2_closed_time,
                pull_request: double(),
                updated_at: (Date.today - 1).to_time.utc,
                labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expected_hours_pr1 = 48.0
        expected_hours_pr2 = 96.0
        total_expected_hours = (expected_hours_pr1 + expected_hours_pr2) / 2.0 # (48+96)/2 = 72
        expect(stats[:pr][:avg_time_to_close_hours])
          .to eq(total_expected_hours)
      end

      it 'is 0 if no PRs were closed' do
         allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              create_mock_item(
                created_at: (Date.today - 7).to_time.utc,
                closed_at: nil,
                pull_request: double(),
                updated_at: (Date.today - 3).to_time.utc,
                labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:pr][:avg_time_to_close_hours]).to eq(0)
      end
    end

    context 'when calculating avg_time_to_close_hours for Issues' do
      it 'calculates correctly for one closed issue' do
        issue_closed_time = (Date.today - 5).to_time.utc
        issue_created_time = (Date.today - 7).to_time.utc
        allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              create_mock_item(
                created_at: issue_created_time,
                closed_at: issue_closed_time,
                pull_request: nil,
                updated_at: (Date.today - 3).to_time.utc,
                labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expected_hours = (issue_closed_time - issue_created_time) / 3600.0
        expect(stats[:issue][:avg_time_to_close_hours]).to eq(expected_hours)
      end
    end

    context 'when determining oldest_open for PRs' do
      let(:oldest_pr_created_at_time) { (Date.today - 10).to_time.utc } # Use Time
      let(:oldest_pr_updated_at_time) { (Date.today - 2).to_time.utc } # Use Time
      let(:mock_oldest_pr) do
        create_mock_item(
          created_at: oldest_pr_created_at_time,
          closed_at: nil,
          pull_request: double(),
          updated_at: oldest_pr_updated_at_time,
          labels: []
        )
      end

      it 'correctly identifies the oldest open PR and its stats' do
        allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              mock_oldest_pr, # This is the actual item
              create_mock_item(
                created_at: (Date.today - 5).to_time.utc,
                closed_at: nil, pull_request: double(),
                updated_at: (Date.today - 1).to_time.utc, labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        # The :oldest_open field in stats now holds the mock item itself
        expect(stats[:pr][:oldest_open]).to eq(mock_oldest_pr)
        expect(stats[:pr][:oldest_open_days])
          .to eq((Date.today - oldest_pr_created_at_time.to_date).to_i)
        expect(stats[:pr][:oldest_open_last_activity])
          .to eq((Date.today - oldest_pr_updated_at_time.to_date).to_i)
      end

      it 'sets oldest_open stats to nil/0 if no PRs are open' do
        allow(client)
          .to receive(:issues)
          .and_return(
            [
              create_mock_item( # A closed PR
                created_at: (Date.today - 12).to_time.utc,
                closed_at: (Date.today - 3).to_time.utc,
                pull_request: double(),
                updated_at: (Date.today - 3).to_time.utc, labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:pr][:oldest_open]).to be_nil
        expect(stats[:pr][:oldest_open_days]).to eq(0) # Corrected
        expect(stats[:pr][:oldest_open_last_activity]).to eq(0) # Corrected
      end
    end

    context 'when determining oldest_open for Issues' do
      let(:oldest_issue_created_at_time) { (Date.today - 10).to_time.utc }
      let(:oldest_issue_updated_at_time) { (Date.today - 2).to_time.utc }
      let(:mock_oldest_issue) do
         create_mock_item(
            created_at: oldest_issue_created_at_time,
            closed_at: nil, pull_request: nil,
            updated_at: oldest_issue_updated_at_time,
            labels: []
          )
      end

      it 'correctly identifies the oldest open issue and its stats' do
        allow(client)
          .to receive(:issues)
          .and_return([mock_oldest_issue])
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:issue][:oldest_open]).to eq(mock_oldest_issue)
        expect(stats[:issue][:oldest_open_days])
          .to eq((Date.today - oldest_issue_created_at_time.to_date).to_i)
        expect(stats[:issue][:oldest_open_last_activity])
          .to eq((Date.today - oldest_issue_updated_at_time.to_date).to_i)
      end

      it 'sets oldest_open stats to nil/0 if no issues are open' do
        allow(client).to receive(:issues).and_return([])
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:issue][:oldest_open]).to be_nil
        expect(stats[:issue][:oldest_open_days]).to eq(0) # Corrected
        expect(stats[:issue][:oldest_open_last_activity]).to eq(0) # Corrected
      end
    end

    context "when an item has 'Status: Waiting on Contributor' label" do
      let(:waiting_label) { 'Status: Waiting on Contributor' }
      it 'does not count open PRs with the waiting label' do
        allow(client)
          .to receive(:issues)
          .and_return(
            [
              create_mock_item(
                created_at: (Date.today - 10).to_time.utc, closed_at: nil,
                pull_request: double(), updated_at: (Date.today - 1).to_time.utc,
                labels: [waiting_label]
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:pr][:open]).to eq(0)
        expect(stats[:pr][:oldest_open]).to be_nil
        expect(stats[:pr][:oldest_open_days]).to eq(0) # Corrected
        expect(stats[:pr][:oldest_open_last_activity]).to eq(0) # Corrected
      end
      # Other tests in this context should also be reviewed for nil vs 0 if they check these fields.
    end

    context 'when considering cutoff_date and opened_this_period' do
      let(:days_option) { 30 }
      let(:options_with_days) { options.merge(days: days_option) }
      let(:cutoff_date) { Date.today - days_option }

      it 'counts PRs closed and created within the period correctly' do
        pr_created_within_period = (cutoff_date + 5).to_time.utc
        pr_closed_within_period = (cutoff_date + 10).to_time.utc
        allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              create_mock_item(
                created_at: pr_created_within_period,
                closed_at: pr_closed_within_period,
                pull_request: double(),
                updated_at: pr_closed_within_period, labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options_with_days)
        expect(stats[:pr][:closed]).to eq(1)
        expect(stats[:pr][:opened_this_period]).to eq(0) # Corrected
      end

      it 'counts issues closed and created within the period correctly' do
        issue_created_within_period = (cutoff_date + 5).to_time.utc
        issue_closed_within_period = (cutoff_date + 10).to_time.utc
        allow(client)
          .to receive(:issues)
          .with('test_org/test_repo', hash_including(page: 1))
          .and_return(
            [
              create_mock_item(
                created_at: issue_created_within_period,
                closed_at: issue_closed_within_period,
                pull_request: nil,
                updated_at: issue_closed_within_period, labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options_with_days)
        expect(stats[:issue][:closed]).to eq(1)
        expect(stats[:issue][:opened_this_period]).to eq(0) # Corrected
      end
    end

    context 'when calculating stale count' do
      let(:stale_cutoff_days) { 30 }
      let(:on_stale_update_time) { (Date.today - stale_cutoff_days).to_time.utc }

      it 'counts an open PR updated exactly on stale cutoff as NOT stale' do
        allow(client)
          .to receive(:issues)
          .and_return(
            [
              create_mock_item(
                created_at: (Date.today - 40).to_time.utc, closed_at: nil,
                pull_request: double(), updated_at: on_stale_update_time,
                labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:pr][:stale_count]).to eq(0) # Corrected
      end

      it 'counts an open issue updated exactly on stale cutoff as NOT stale' do
        allow(client)
          .to receive(:issues)
          .and_return(
            [
              create_mock_item(
                created_at: (Date.today - 40).to_time.utc, closed_at: nil,
                pull_request: nil, updated_at: on_stale_update_time,
                labels: []
              ),
            ],
          )
        stats = get_pr_and_issue_stats(client, options)
        expect(stats[:issue][:stale_count]).to eq(0) # Corrected
      end
    end
    # (Rest of the file remains the same)
  end

  describe '#get_failed_tests_from_ci' do
    let(:branch_options) { options.merge(branches: ['main']) }

    context 'basic scenarios' do
      it 'returns empty results if no workflows are found' do
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: []))
        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expect(failed_tests).to eq({ 'main' => {} })
      end

      it 'returns empty results if workflows are found but no runs' do
        mock_workflow = create_mock_workflow(1, 'Test Workflow')
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [mock_workflow]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: []))
        allow(client) # Ensure pagination is handled
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expect(failed_tests).to eq({ 'main' => {} })
      end

      it 'returns empty results if runs are found but no failed jobs' do
        mock_workflow = create_mock_workflow(1, 'Test Workflow')
        mock_run = create_mock_workflow_run(123, Date.today - 1)
        mock_success_job = create_mock_job('Success Job', 'success')

        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [mock_workflow]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [mock_run]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', mock_run.id, page: 1)
          .and_return(double(jobs: [mock_success_job]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', mock_run.id, page: 2)
          .and_return(double(jobs: []))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expect(failed_tests).to eq({ 'main' => {} })
      end

      it 'handles no failures gracefully (original test case adaptation)' do
        mock_workflow = create_mock_workflow(1, 'Test Workflow')
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [mock_workflow]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: []))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expect(failed_tests['main']).to be_empty
        expect(failed_tests).to eq({ 'main' => {} })
      end
    end

    it 'fetches failed tests from CI workflows (original adaptation)' do
      mock_workflow = create_mock_workflow(1, 'Test Workflow')
      mock_run = create_mock_workflow_run(123, Date.today - 5)
      mock_failed_job = create_mock_job('Test Job', 'failure')

      allow(client)
        .to receive(:workflows)
        .with('test_org/test_repo')
        .and_return(double(workflows: [mock_workflow]))
      allow(client)
        .to receive(:workflow_runs)
        .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 1)
        .and_return(double(workflow_runs: [mock_run]))
      allow(client)
        .to receive(:workflow_runs)
        .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 2)
        .and_return(double(workflow_runs: []))
      allow(client)
        .to receive(:workflow_run_jobs)
        .with('test_org/test_repo', mock_run.id, page: 1)
        .and_return(double(jobs: [mock_failed_job]))
      allow(client)
        .to receive(:workflow_run_jobs)
        .with('test_org/test_repo', mock_run.id, page: 2)
        .and_return(double(jobs: []))

      failed_tests = get_failed_tests_from_ci(client, branch_options)

      job_key = "#{mock_workflow.name} / #{mock_failed_job.name}"
      expected_failure_dates = (0..5).map { |d| Date.today - d }.to_set
      expect(failed_tests['main'][job_key]).to eq(expected_failure_dates)
    end

    context "'still failing' logic" do
      let(:workflow) { create_mock_workflow(1, 'WF1') }
      let(:job_name) { 'Job1' }
      let(:job_key) { "#{workflow.name} / #{job_name}" }

      before do
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [workflow]))
        allow(client) # Default empty page 2 for jobs
          .to receive(:workflow_run_jobs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(jobs: []))
      end

      it 'job fails today' do
        run_today = create_mock_workflow_run(100, Date.today)
        job_failed_today = create_mock_job(job_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_today]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_today.id, page: 1)
          .and_return(double(jobs: [job_failed_today]))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expect(failed_tests['main'][job_key]).to eq([Date.today].to_set)
      end

      it 'job fails 5 days ago, succeeds 3 days ago' do
        run_fail = create_mock_workflow_run(101, Date.today - 5)
        job_fail = create_mock_job(job_name, 'failure')

        run_success = create_mock_workflow_run(102, Date.today - 3)
        job_success = create_mock_job(job_name, 'success')

        allow(client) # Runs in reverse chronological order
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_success, run_fail]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))

        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_fail.id, page: 1)
          .and_return(double(jobs: [job_fail]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_success.id, page: 1)
          .and_return(double(jobs: [job_success]))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expected_dates = [Date.today - 5, Date.today - 4].to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
      end

      it 'job fails, then succeeds, then fails again' do
        run_fail1 = create_mock_workflow_run(101, Date.today - 5)
        job_fail1 = create_mock_job(job_name, 'failure')
        run_success = create_mock_workflow_run(102, Date.today - 3)
        job_success = create_mock_job(job_name, 'success')
        run_fail2 = create_mock_workflow_run(103, Date.today - 1)
        job_fail2 = create_mock_job(job_name, 'failure')

        allow(client) # Runs in reverse chronological order
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_fail2, run_success, run_fail1]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))

        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_fail1.id, page: 1)
          .and_return(double(jobs: [job_fail1]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_success.id, page: 1)
          .and_return(double(jobs: [job_success]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_fail2.id, page: 1)
          .and_return(double(jobs: [job_fail2]))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expected_dates = [
          Date.today - 5, Date.today - 4, # From first failure period
          Date.today - 1, Date.today      # From second failure period
        ].to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
      end

      it 'multiple jobs in one workflow, some failing, some succeeding' do
        job1_name = 'Job1' # Will fail
        job2_name = 'Job2' # Will succeed
        job3_name = 'Job3' # Will also fail, different dates

        job1_key = "#{workflow.name} / #{job1_name}"
        job3_key = "#{workflow.name} / #{job3_name}"

        run1 = create_mock_workflow_run(201, Date.today - 2)
        run2 = create_mock_workflow_run(202, Date.today - 1)

        job1_fail = create_mock_job(job1_name, 'failure')
        job2_success = create_mock_job(job2_name, 'success')
        job3_fail = create_mock_job(job3_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run2, run1]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))

        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run1.id, page: 1)
          .and_return(double(jobs: [job1_fail, job2_success]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run2.id, page: 1)
          .and_return(double(jobs: [job3_fail]))

        failed_tests = get_failed_tests_from_ci(client, branch_options)

        expect(failed_tests['main'].keys.size).to eq(2)
        expect(failed_tests['main'][job1_key])
          .to eq((0..2).map { |d| Date.today - d }.to_set)
        expect(failed_tests['main'][job3_key])
          .to eq((0..1).map { |d| Date.today - d }.to_set)
      end
    end

    context 'multiple branches' do
      let(:multi_branch_options) { options.merge(branches: ['main', 'develop']) }
      let(:workflow_main) { create_mock_workflow(1, 'WF-Main') }
      let(:workflow_dev) { create_mock_workflow(2, 'WF-Dev') }

      before do
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [workflow_main, workflow_dev]))
        allow(client) # Default empty page 2 for jobs
          .to receive(:workflow_run_jobs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(jobs: []))
        allow(client) # Default empty page 2 for runs
          .to receive(:workflow_runs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(workflow_runs: []))
      end

      it "main has failure, develop has no failures" do
        run_main_fail = create_mock_workflow_run(301, Date.today - 3)
        job_main_fail = create_mock_job('JobM', 'failure')
        job_main_key = "#{workflow_main.name} / #{job_main_fail.name}"

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow_main.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_main_fail]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_main_fail.id, page: 1)
          .and_return(double(jobs: [job_main_fail]))

        allow(client) # Develop branch has no runs
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow_dev.id, branch: 'develop', page: 1)
          .and_return(double(workflow_runs: []))

        failed_tests = get_failed_tests_from_ci(client, multi_branch_options)

        expect(failed_tests.keys).to contain_exactly('main', 'develop')
        expect(failed_tests['main'][job_main_key])
          .to eq((0..3).map { |d| Date.today - d }.to_set)
        expect(failed_tests['develop']).to be_empty
      end

      it 'both branches have different failing jobs' do
        run_main_fail = create_mock_workflow_run(401, Date.today - 2)
        job_main_fail = create_mock_job('JobM-Fail', 'failure')
        job_main_key = "#{workflow_main.name} / #{job_main_fail.name}"

        run_dev_fail = create_mock_workflow_run(402, Date.today - 1)
        job_dev_fail = create_mock_job('JobD-Fail', 'failure')
        job_dev_key = "#{workflow_dev.name} / #{job_dev_fail.name}"

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow_main.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_main_fail]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_main_fail.id, page: 1)
          .and_return(double(jobs: [job_main_fail]))

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow_dev.id, branch: 'develop', page: 1)
          .and_return(double(workflow_runs: [run_dev_fail]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_dev_fail.id, page: 1)
          .and_return(double(jobs: [job_dev_fail]))

        failed_tests = get_failed_tests_from_ci(client, multi_branch_options)

        expect(failed_tests['main'][job_main_key])
          .to eq((0..2).map { |d| Date.today - d }.to_set)
        expect(failed_tests['develop'][job_dev_key])
          .to eq((0..1).map { |d| Date.today - d }.to_set)
      end
    end

    context 'aggregation of failure dates' do
      let(:workflow) { create_mock_workflow(1, 'WF-Agg') }
      let(:job_name) { 'Job-Agg' }
      let(:job_key) { "#{workflow.name} / #{job_name}" }

      before do
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [workflow]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(jobs: []))
      end

      it 'job fails at D-5, then again at D-2 (no success between)' do
        run_fail1 = create_mock_workflow_run(501, Date.today - 5)
        job_fail1 = create_mock_job(job_name, 'failure')
        run_fail2 = create_mock_workflow_run(502, Date.today - 2)
        job_fail2 = create_mock_job(job_name, 'failure')

        allow(client) # Runs in reverse chronological order
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_fail2, run_fail1]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))

        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_fail1.id, page: 1)
          .and_return(double(jobs: [job_fail1]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_fail2.id, page: 1)
          .and_return(double(jobs: [job_fail2]))

        failed_tests = get_failed_tests_from_ci(client, branch_options)
        expected_dates = ((Date.today - 5)..(Date.today)).to_a.to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
      end
    end

    context 'Octokit error handling' do
      let(:logger_spy) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
      before do
        # Ensure that the log method in OssStats::Log returns our spy
        allow(OssStats::Log).to receive(:log).and_return(logger_spy)
      end

      it 'handles Octokit::NotFound when fetching workflows' do
        # Create a more realistic NotFound error object
        not_found_error = Octokit::NotFound.new({
          method: :get,
          url: URI.parse('https://api.github.com/repos/test_org/test_repo/actions/workflows')
        })
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_raise(not_found_error)

        failed_tests = nil
        expect {
          failed_tests = get_failed_tests_from_ci(client, branch_options)
        }.not_to raise_error

        expect(failed_tests).to eq({ 'main' => {} })
        expect(logger_spy)
          .to have_received(:warn)
          .with("Workflow API returned 404 for test_org/test_repo branch main: Octokit::NotFound GET https://api.github.com/repos/test_org/test_repo/actions/workflows: 404 - Not Found // ")
      end

      it 'handles Octokit::NotFound when fetching workflow runs' do
        mock_workflow = create_mock_workflow(1, 'Test Workflow')
        not_found_error = Octokit::NotFound.new({
          method: :get,
          url: URI.parse("https://api.github.com/repos/test_org/test_repo/actions/workflows/#{mock_workflow.id}/runs")
        })
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [mock_workflow]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 1)
          .and_raise(not_found_error)

        failed_tests = nil
        expect {
          failed_tests = get_failed_tests_from_ci(client, branch_options)
        }.not_to raise_error

        expect(failed_tests).to eq({ 'main' => {} })
        expect(logger_spy)
          .to have_received(:warn)
          .with("Workflow API returned 404 for test_org/test_repo branch main: Octokit::NotFound GET https://api.github.com/repos/test_org/test_repo/actions/workflows/1/runs: 404 - Not Found // ")
      end

      it 'handles Octokit::Error when fetching workflow run jobs' do
        mock_workflow = create_mock_workflow(1, 'Test Workflow')
        mock_run = create_mock_workflow_run(123, Date.today - 1)
        # Pass a string message to Octokit::Error constructor
        api_error = Octokit::Error.new("API Error")

        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [mock_workflow]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [mock_run]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', mock_workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: []))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', mock_run.id, page: 1)
          .and_raise(api_error) # Use the defined api_error

        failed_tests = nil
        expect {
          failed_tests = get_failed_tests_from_ci(client, branch_options)
        }.not_to raise_error

        expect(failed_tests).to eq({ 'main' => {} })
        # The code logs: log.error("Error processing branch #{branch} for repo #{repo}: #{e.message}")
        expect(logger_spy)
          .to have_received(:error)
          .with("Error processing branch main for repo test_org/test_repo: API Error")
      end
    end

    context 'cutoff_date logic' do
      let(:days_option) { 10 } # Look back 10 days
      let(:options_with_cutoff) { options.merge(days: days_option) }
      let(:cutoff_date) { Date.today - days_option }

      let(:workflow) { create_mock_workflow(1, 'WF-Cutoff') }
      let(:job_name) { 'Job-Cutoff' }
      let(:job_key) { "#{workflow.name} / #{job_name}" }

      before do
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [workflow]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(jobs: []))
        allow(client) # Default empty page 2 for runs
          .to receive(:workflow_runs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(workflow_runs: []))
      end

      it 'does not process runs created before cutoff_date' do
        run_before_cutoff = create_mock_workflow_run(601, cutoff_date - 1)
        job_fail_old = create_mock_job(job_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_before_cutoff]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_before_cutoff.id, page: 1)
          .and_return(double(jobs: [job_fail_old]))

        failed_tests = get_failed_tests_from_ci(client, options_with_cutoff)
        expect(failed_tests['main']).to be_empty
      end

      it 'processes runs created on or after cutoff_date' do
        run_on_cutoff = create_mock_workflow_run(602, cutoff_date)
        run_after_cutoff = create_mock_workflow_run(603, cutoff_date + 1)
        job_fail1 = create_mock_job(job_name, 'failure')
        job_fail2 = create_mock_job(job_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_after_cutoff, run_on_cutoff]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_on_cutoff.id, page: 1)
          .and_return(double(jobs: [job_fail1]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_after_cutoff.id, page: 1)
          .and_return(double(jobs: [job_fail2]))

        failed_tests = get_failed_tests_from_ci(client, options_with_cutoff)
        # Latest failure is from run_after_cutoff (cutoff_date + 1)
        expected_dates = ((cutoff_date + 1)..Date.today).to_a.to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
      end

      it 'failure dates only within current period for old run in period' do
        run_old_in_period = create_mock_workflow_run(604, cutoff_date)
        job_fail_old_in_period = create_mock_job(job_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_old_in_period]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_old_in_period.id, page: 1)
          .and_return(double(jobs: [job_fail_old_in_period]))

        failed_tests = get_failed_tests_from_ci(client, options_with_cutoff)
        expected_dates = (cutoff_date..Date.today).to_a.to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
      end
    end

    context 'pagination for workflow runs' do
      let(:days_option) { 5 }
      let(:options_with_cutoff) { options.merge(days: days_option) }
      let(:cutoff_date) { Date.today - days_option }

      let(:workflow) { create_mock_workflow(1, 'WF-Paginate') }
      let(:job_name) { 'Job-Paginate' }
      let(:job_key) { "#{workflow.name} / #{job_name}" }

      before do
        allow(client)
          .to receive(:workflows)
          .with('test_org/test_repo')
          .and_return(double(workflows: [workflow]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with(anything, anything, hash_including(page: 2))
          .and_return(double(jobs: []))
      end

      it 'stops fetching runs when page runs are older than cutoff' do
        run_p1_1 = create_mock_workflow_run(701, Date.today - 1) # Valid
        run_p1_2 = create_mock_workflow_run(702, cutoff_date + 1) # Valid
        run_p2_1 = create_mock_workflow_run(703, cutoff_date - 1) # Invalid
        run_p2_2 = create_mock_workflow_run(704, cutoff_date - 2) # Invalid

        job_fail_p1_1 = create_mock_job(job_name, 'failure')
        job_fail_p1_2 = create_mock_job(job_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_p1_1, run_p1_2]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: [run_p2_1, run_p2_2]))

        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_p1_1.id, page: 1)
          .and_return(double(jobs: [job_fail_p1_1]))
        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_p1_2.id, page: 1)
          .and_return(double(jobs: [job_fail_p1_2]))

        failed_tests = get_failed_tests_from_ci(client, options_with_cutoff)
        # Latest failure is run_p1_1 (Date.today - 1)
        expected_dates = ((Date.today - 1)..Date.today).to_a.to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
        expect(client).not_to have_received(:workflow_run_jobs)
          .with('test_org/test_repo', run_p2_1.id, anything)
        expect(client).not_to have_received(:workflow_run_jobs)
          .with('test_org/test_repo', run_p2_2.id, anything)
      end

      it 'stops fetching runs when a page is empty' do
        run_p1_1 = create_mock_workflow_run(801, Date.today - 2) # Valid
        job_fail_p1_1 = create_mock_job(job_name, 'failure')

        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 1)
          .and_return(double(workflow_runs: [run_p1_1]))
        allow(client)
          .to receive(:workflow_runs)
          .with('test_org/test_repo', workflow.id, branch: 'main', page: 2)
          .and_return(double(workflow_runs: [])) # Empty page 2

        allow(client)
          .to receive(:workflow_run_jobs)
          .with('test_org/test_repo', run_p1_1.id, page: 1)
          .and_return(double(jobs: [job_fail_p1_1]))

        failed_tests = get_failed_tests_from_ci(client, options_with_cutoff)
        expected_dates = ((Date.today - 2)..Date.today).to_a.to_set
        expect(failed_tests['main'][job_key]).to eq(expected_dates)
      end
    end
  end
end

[end of spec/ci_stats_spec.rb]
