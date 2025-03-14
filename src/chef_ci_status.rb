#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'set'

# Get GitHub token
def get_github_token
  config_path = File.expand_path('~/.config/gh/hosts.yml')
  if File.exist?(config_path)
    config = YAML.load_file(config_path)
    return config.dig('github.com', 'oauth_token')
  end
  nil
end

# Fetch PR and Issue stats from GitHub in a single API call
def get_pr_and_issue_stats(client, options)
  repo = "#{options[:org]}/#{options[:repo]}"
  cutoff_date = Date.today - options[:days]
  pr_stats = {
    opened: 0, closed: 0, total_close_time: 0.0, oldest_open: nil,
    oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0
  }
  issue_stats = {
    opened: 0, closed: 0, total_close_time: 0.0, oldest_open: nil,
    oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0
  }
  stale_cutoff = Date.today - 30
  page = 1

  loop do
    items = client.issues(repo, state: 'all', per_page: 100, page:)
    break if items.empty?

    all_items_before_cutoff = true

    items.each do |item|
      created_date = item.created_at.to_date
      closed_date = item.closed_at&.to_date
      is_pr = !item.pull_request.nil?
      last_comment_date = item.updated_at.to_date
      labels = item.labels.map(&:name)
      days_open = (Date.today - created_date).to_i
      days_since_last_activity = (Date.today - last_comment_date).to_i

      if options[:verbose]
        puts "Checking item: #{is_pr ? 'PR' : 'Issue'}, " +
             "Created at #{created_date}, Closed at #{closed_date || 'N/A'}"
      end

      stats = is_pr ? pr_stats : issue_stats

      # Track oldest open PR/Issue with days open and last activity days
      if closed_date.nil? &&
         (stats[:oldest_open].nil? || created_date < stats[:oldest_open])
        stats[:oldest_open] = created_date
        stats[:oldest_open_days] = days_open
        stats[:oldest_open_last_activity] = days_since_last_activity
      end

      if closed_date.nil? && last_comment_date < stale_cutoff &&
         !labels.include?('Status: Waiting on Contributor')
        stats[:stale_count] += 1
      end

      # Only count if the created date is within the cutoff window
      if created_date >= cutoff_date
        stats[:opened] += 1
        all_items_before_cutoff = false
      end

      # Only count as closed if it was actually closed within the cutoff window
      next unless closed_date && closed_date >= cutoff_date
      stats[:closed] += 1
      stats[:total_close_time] += (item.closed_at - item.created_at) / 3600.0
      all_items_before_cutoff = false
    end

    page += 1
    break if all_items_before_cutoff
  end

  pr_stats[:avg_time_to_close_hours] =
    pr_stats[:closed] == 0 ? 0 : pr_stats[:total_close_time] / pr_stats[:closed]
  issue_stats[:avg_time_to_close_hours] =
    if issue_stats[:closed] == 0
      0
    else
      issue_stats[:total_close_time] / issue_stats[:closed]
    end

  { pr: pr_stats, issue: issue_stats }
end

def get_failed_tests_from_ci(client, options)
  repo = "#{options[:org]}/#{options[:repo]}"
  cutoff_date = Date.today - options[:days]
  today = Date.today
  failed_tests = {}
  options[:branches].each do |b|
    failed_tests[b] = {}
  end

  options[:branches].each do |branch|
    puts "Checking workflow runs for branch: #{branch}" if options[:verbose]

    workflows = client.workflows(repo).workflows
    workflows.each do |workflow|
      puts "Workflow: #{workflow.name}" if options[:verbose]
      workflow_runs = []
      page = 1
      loop do
        puts "  Acquiring page #{page}" if options[:verbose]
        runs = client.workflow_runs(repo, workflow.id, branch:,
status: 'completed', per_page: 100, page:)
        break if runs.workflow_runs.empty?

        workflow_runs.concat(runs.workflow_runs)
        break if runs.workflow_runs.last.created_at.to_date < cutoff_date

        page += 1
      end

      workflow_runs.sort_by!(&:created_at)
      last_failure_date = {}
      workflow_runs.each do |run|
        puts "  Looking at workflow run #{run.id}" if options[:verbose]
        run_date = run.created_at.to_date
        next if run_date < cutoff_date

        jobs = client.workflow_run_jobs(repo, run.id).jobs
        jobs.each do |job|
          if options[:verbose]
            puts "    Looking at job #{job.name} [#{job.conclusion}]"
          end
          if job.conclusion == 'failure'
            failed_tests[branch][job.name] ||= Set.new
          end
          last_date = last_failure_date[job.name]

          if last_date
            while last_date < run_date
              failed_tests[branch][job.name] << last_date
              last_date += 1
            end
          end

          if job.conclusion == 'failure'
            failed_tests[branch][job.name] << run_date
            last_failure_date[job.name] = run_date
          elsif job.conclusion == 'success'
            last_failure_date.delete(job.name)
          end
        rescue StandardError => e
          puts "Error getting jobs for run #{run.id}: #{e}"
          next
        end
      end

      last_failure_date.each do |job_name, last_date|
        while last_date < today
          failed_tests[branch][job_name] << last_date
          last_date += 1
        end
      end
    end
  end

  failed_tests
end

options = {
  org: 'chef',
  repo: 'chef',
  branches: ['main'],
  days: 30,
  verbose: false,
  mode: ['all'],
}

valid_modes = %w(ci pr issue all)
OptionParser.new do |opts|
  opts.banner = 'Usage: chef_ci_status.rb [options]'

  opts.on(
    '--org ORG',
    "GitHub org name (default: #{options[:org]})",
  ) do |v|
    options[:org] = v
  end

  opts.on(
    '--repo REPO',
    "GitHub repository name (default: #{options[:repo]})",
  ) do |v|
    options[:repo] = v
  end

  opts.on(
    '--branches BRANCHES',
    Array,
    "Comma-separated list of branches (default: #{options[:branches]})",
  ) do |v|
    options[:branches] = v
  end

  opts.on(
    '--days DAYS',
    Integer,
    "Number of days to analyze (default: #{options[:days]})",
  ) do |v|
    options[:days] = v
  end

  opts.on(
    '--mode MODE',
    Array,
    'Comma-separated list of modes: ci,issue,pr, or all (default: all)',
  ) do |v|
    invalid_modes = v - valid_modes
    unless invalid_modes.empty?
      raise OptionParser::InvalidArgument,
        "Invalid mode(s): #{invalid_modes.join(', ')}." +
        "Valid modes are: #{valid_modes.join(', ')}"
    end

    options[:mode] = v
  end

  opts.on(
    '-v',
    '--verbose',
    "Enable verbose output (default: #{options[:verbose]})",
  ) do
    options[:verbose] = true
  end
end.parse!
options[:mode] = %w(ci pr issue) if options[:mode].include?('all')

if options[:verbose]
  puts "Options: #{options}"
end

github_token = get_github_token
raise 'GitHub token not found in ~/.config/gh/hosts.yml' unless github_token

client = Octokit::Client.new(access_token: github_token)

puts "[#{options[:org]}/#{options[:repo]}] Stats (Last #{options[:days]} days)"

if options[:mode].include?('pr') || options[:mode].include?('issue')
  stats = get_pr_and_issue_stats(client, options)

  if options[:mode].include?('pr')
    puts "\n  PR Stats:"
    puts "    Opened PRs: #{stats[:pr][:opened]}"
    puts "    Closed PRs: #{stats[:pr][:closed]}"
    puts "    Oldest Open PR: #{stats[:pr][:oldest_open] || 'N/A'}" +
         " (#{stats[:pr][:oldest_open_days]} days open, last activity" +
         " #{stats[:pr][:oldest_open_last_activity]} days ago)"
    puts "    Stale PRs (>30 days without comment): #{stats[:pr][:stale_count]}"
    avg_time = stats[:pr][:avg_time_to_close_hours]
    avg_time_str = if avg_time > 24
                     (avg_time / 24).round(2).to_s + ' days'
                   else
                     avg_time.round(2).to_s + ' hours'
                   end
    puts "    Avg Time to Close PRs: #{avg_time_str}"
  end

  if options[:mode].include?('issue')
    puts "\n  Issue Stats:"
    puts "    Opened Issues: #{stats[:issue][:opened]}"
    puts "    Closed Issues: #{stats[:issue][:closed]}"
    puts "    Oldest Open Issue: #{stats[:issue][:oldest_open] || 'N/A'}" +
         " (#{stats[:issue][:oldest_open_days]} days open, last activity" +
         " #{stats[:issue][:oldest_open_last_activity]} days ago)"
    puts '    Stale Issues (>30 days without comment): ' +
         stats[:issue][:stale_count].to_s
    avg_time = stats[:issue][:avg_time_to_close_hours]
    avg_time_str = if avg_time > 24
                     (avg_time / 24).round(2).to_s + ' days'
                   else
                     avg_time.round(2).to_s + ' hours'
                   end
    puts "    Avg Time to Close Issues: #{avg_time_str}"
  end
end

if options[:mode].include?('ci')
  test_failures = get_failed_tests_from_ci(client, options)
  puts "\n  CI Failure Stats:"
  test_failures.each do |branch, jobs|
    puts "    Branch: #{branch}"
    if jobs.empty?
      puts '      No job failures found.'
    else
      jobs.sort.each do |job, dates|
        puts "      #{job}: #{dates.size} days"
      end
    end
  end
end
