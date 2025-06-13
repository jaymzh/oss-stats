#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'set'

require_relative 'lib/oss_stats/log'
require_relative 'lib/oss_stats/github_token'

# Fetches all 'issues' (which can include PRs) from a repository,
# paginating until items are older than the cutoff_date or no more items are found.
def get_github_items(client, repo, cutoff_date)
  all_items = []
  page = 1
  loop do
    items = client.issues(repo, state: 'all', per_page: 100, page:)
    break if items.empty?

    items_before_cutoff_in_this_page = false
    items.each do |item|
      # Check if any item in the current page is within the cutoff_date
      # This helps in deciding if we need to fetch the next page
      created_date = item.created_at.to_date
      closed_date = item.closed_at&.to_date
      if created_date >= cutoff_date || (closed_date && closed_date >= cutoff_date)
        items_before_cutoff_in_this_page = true
      end
      all_items << item
    end

    # If all items in the current page are older than the cutoff_date,
    # we can stop paginating. However, we've already added them to all_items.
    # The filtering of these items will happen during statistics calculation.
    # The primary goal here is to optimize by not fetching unnecessary pages.
    break unless items_before_cutoff_in_this_page

    page += 1
  end
  all_items
end

# Utility function to sleep if rate limiting is specified
def rate_limited_sleep(options)
  if options[:limit_gh_ops_per_minute]&.positive?
    sleep_time = 60.0 / options[:limit_gh_ops_per_minute]
    log.debug("Sleeping for #{sleep_time} to honor rate-limit")
    sleep(sleep_time)
  end
end

# Updated get_github_items to use options and include rate_limited_sleep
# Fetches all 'issues' (which can include PRs) from a repository.
def get_github_items(client, repo, options)
  all_fetched_items = []
  page = 1
  cutoff_date = Date.today - options[:days]

  loop do
    log.debug("Fetching page #{page} of items for #{repo}")
    current_page_items = client.issues(repo, state: 'all', per_page: 100, page:)
    rate_limited_sleep(options) # Respect rate limits
    break if current_page_items.empty?

    # This optimization helps stop fetching pages if all items on a page are older than the cutoff.
    # It assumes items are roughly sorted by update/creation time by GitHub's API for 'all' state.
    # A more robust check might involve checking each item's relevant dates.
    last_item_on_page = current_page_items.last
    # Use updated_at as a general proxy for activity. If an item was updated recently,
    # it could be relevant, or new items could be on later pages.
    # If the last item on the page was updated before our cutoff,
    # it's less likely (though not impossible) that subsequent pages will have relevant items.
    # This is an optimization and might need refinement for strict accuracy in all edge cases.
    break if last_item_on_page.updated_at.to_date < cutoff_date && page > 1 # Avoid breaking on first page

    all_fetched_items.concat(current_page_items)
    page += 1
  end
  all_fetched_items
end

# Calculates statistics for a list of GitHub items (PRs or issues).
def calculate_item_stats(items_list, item_type, options) # item_type is 'pr' or 'issue'
  stats = {
    open: 0, closed: 0, total_close_time: 0.0, oldest_open: nil,
    oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0,
    opened_this_period: 0
  }
  item_collection = { open: [], closed: [] } # Renamed from 'list' to avoid conflict
  cutoff_date = Date.today - options[:days]
  stale_cutoff = Date.today - 30 # 30 days for staleness

  items_list.each do |item|
    is_item_pr = !item.pull_request.nil?
    current_item_type = is_item_pr ? 'pr' : 'issue'

    next unless current_item_type == item_type # Process only the specified item_type

    created_date = item.created_at.to_date
    closed_date = item.closed_at&.to_date
    last_comment_date = item.updated_at.to_date # Using updated_at for last activity
    labels = item.labels.map(&:name)
    days_open = (Date.today - created_date).to_i
    days_since_last_activity = (Date.today - last_comment_date).to_i

    log.debug(
      "Calculating stats for #{item_type} ##{item.number}: " +
      "Created at #{created_date}, Closed at #{closed_date || 'N/A'}",
    )

    # Calculate stats for open items
    if closed_date.nil? && !labels.include?('Status: Waiting on Contributor')
      if stats[:oldest_open].nil? || created_date < stats[:oldest_open]
        stats[:oldest_open] = created_date
        stats[:oldest_open_days] = days_open
        stats[:oldest_open_last_activity] = days_since_last_activity
      end

      stats[:stale_count] += 1 if last_comment_date < stale_cutoff
      stats[:open] += 1

      if created_date >= cutoff_date
        stats[:opened_this_period] += 1
        item_collection[:open] << item
      end
    end

    # Calculate stats for closed items
    next unless closed_date && closed_date >= cutoff_date # Must be closed within the cutoff window

    # If it's a PR, ensure it was closed by merging
    next if is_item_pr && item.pull_request.merged_at.nil?

    item_collection[:closed] << item
    stats[:closed] += 1
    stats[:total_close_time] += (item.closed_at - item.created_at) / 3600.0 # in hours
  end

  stats[:avg_time_to_close_hours] =
    stats[:closed] == 0 ? 0 : stats[:total_close_time] / stats[:closed].to_f

  { stats:, list: item_collection }
end

# Refactored function to use helper methods
def get_pr_and_issue_stats(client, options)
  repo = "#{options[:org]}/#{options[:repo]}"

  # Fetch all items (PRs and issues).
  # The get_github_items function fetches everything, and calculate_item_stats filters by type.
  all_items = get_github_items(client, repo, options) # Pass options now

  # Calculate PR stats
  pr_result = calculate_item_stats(all_items, 'pr', options)

  # Calculate Issue stats
  issue_result = calculate_item_stats(all_items, 'issue', options)

  {
    pr: pr_result[:stats],
    issue: issue_result[:stats],
    pr_list: pr_result[:list],
    issue_list: issue_result[:list]
  }
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
    log.debug("Checking workflow runs for branch: #{branch}")

    workflows = client.workflows(repo).workflows
    workflows.each do |workflow|
      log.debug("Workflow: #{workflow.name}")
      workflow_runs = []
      page = 1
      loop do
        log.debug("  Acquiring page #{page}")
        runs = client.workflow_runs(
          repo, workflow.id, branch:, status: 'completed', per_page: 100, page:
        )
        rate_limited_sleep(options)

        break if runs.workflow_runs.empty?

        workflow_runs.concat(runs.workflow_runs)
        break if runs.workflow_runs.last.created_at.to_date < cutoff_date

        page += 1
      end

      workflow_runs.sort_by!(&:created_at)
      last_failure_date = {}
      workflow_runs.each do |run|
        log.debug("  Looking at workflow run #{run.id}")
        run_date = run.created_at.to_date
        next if run_date < cutoff_date

        jobs = client.workflow_run_jobs(repo, run.id).jobs
        rate_limited_sleep(options)

        jobs.each do |job|
          log.debug("    Looking at job #{job.name} [#{job.conclusion}]")
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
          log.error("Error getting jobs for run #{run.id}: #{e}")
          next
        ensure
          rate_limited_sleep(options)
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

def print_pr_or_issue_stats(data, type, include_list)
  stats = data[type.downcase.to_sym]
  list = data["#{type.downcase}_list".to_sym]
  type_plural = type + 's'
  log.info("\n* #{type} Stats:")
  log.info("    * Closed #{type_plural}: #{stats[:closed]}")
  if include_list
    list[:closed].each do |item|
      log.info(
        "        * [#{item.title} (##{item.number})](#{item.html_url}) " +
        "- @#{item.user.login}",
      )
    end
  end
  log.info(
    "     * Open #{type_plural}: #{stats[:open]} " +
    "(#{include_list ? 'listing ' : ''} #{stats[:opened_this_period]} " +
    'opened this period)',
  )
  if include_list && stats[:opened_this_period] > 0
    list[:open].each do |item|
      log.info(
        "        * [#{item.title} (##{item.number})](#{item.html_url}) " +
        "- @#{item.user.login}",
      )
    end
  end
  if stats[:oldest_open]
    log.info(
      "    * Oldest Open #{type}: #{stats[:oldest_open]}" +
      " (#{stats[:oldest_open_days]} days open, last activity" +
      " #{stats[:oldest_open_last_activity]} days ago)",
    )
  end
  log.info(
    "    * Stale #{type} (>30 days without comment): #{stats[:stale_count]}",
  )
  avg_time = stats[:avg_time_to_close_hours]
  avg_time_str = if avg_time > 24
                   (avg_time / 24).round(2).to_s + ' days'
                 else
                   avg_time.round(2).to_s + ' hours'
                 end
  log.info("    * Avg Time to Close #{type_plural}: #{avg_time_str}")
end

def print_ci_status(test_failures, _options)
  log.info("\n* CI Stats:")
  test_failures.each do |branch, jobs|
    line = "    * Branch: `#{branch}`"
    if jobs.empty?
      line += ': No job failures found! :tada:'
      log.info(line)
    else
      line += ' has the following failures:'
      log.info(line)
      jobs.sort.each do |job, dates|
        log.info("        * #{job}: #{dates.size} days")
      end
    end
  end
end

def parse_options
  options = {
    org: 'chef',
    repo: 'chef',
    branches: ['main'],
    days: 30,
    log_level: :info,
    mode: ['all'],
    include_list: false,
  }
  valid_modes = %w{ci pr issue all}
  OptionParser.new do |opts|
    opts.banner = 'Usage: chef_ci_status.rb [options]'

    opts.on(
      '--branches BRANCHES',
      Array,
      "Comma-separated list of branches (default: #{options[:branches]})",
    ) do |v|
      options[:branches] = v
    end

    opts.on(
      '-d DAYS',
      '--days DAYS',
      Integer,
      "Number of days to analyze (default: #{options[:days]})",
    ) do |v|
      options[:days] = v
    end

    opts.on(
      '--github-token TOKEN',
      'GitHub personal access token (or use GITHUB_TOKEN env var)',
    ) do |val|
      options[:github_token] = val
    end

    opts.on(
      '--limit-gh-ops-per-minute RATE',
      Float,
      'Rate limit GitHub API operations to this number per minute',
    ) do |v|
      options[:limit_gh_ops_per_minute] = v
    end

    opts.on(
      '-l LEVEL',
      '--log-level LEVEL',
      'Set logging level to LEVEL. [default: info]',
    ) do |level|
      options[:log_level] = level.to_sym
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
      '--include-list',
      'Include list of relevant PRs/Issues (default: false)',
    ) do
      options[:include_list] = true
    end
  end.parse!
  options[:mode] = %w{ci pr issue} if options[:mode].include?('all')
  options
end

def main
  options = parse_options
  log.level = options[:log_level] if options[:log_level]

  log.debug("Options: #{options}")

  github_token = get_github_token!(options)
  client = Octokit::Client.new(access_token: github_token)

  log.info(
    "*_[#{options[:org]}/#{options[:repo]}] Stats " +
    "(Last #{options[:days]} days)_*",
  )

  if %w{pr issue}.any? { |x| options[:mode].include?(x) }
    stats = get_pr_and_issue_stats(client, options)

    %w{PR Issue}.each do |item|
      if options[:mode].include?(item.downcase)
        print_pr_or_issue_stats(stats, item, options[:include_list])
      end
    end
  end

  if options[:mode].include?('ci')
    test_failures = get_failed_tests_from_ci(client, options)
    print_ci_status(test_failures, options)
  end
end

main if __FILE__ == $PROGRAM_NAME
