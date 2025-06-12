#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'set'

require_relative 'lib/oss_stats/log'
require_relative 'lib/oss_stats/ci_stats_config'
require_relative 'lib/oss_stats/github_token'

def rate_limited_sleep
  limit_gh_ops_per_minute = OssStats::CiStatsConfig.limit_gh_ops_per_minute
  if limit_gh_ops_per_minute&.positive?
    sleep_time = 60.0 / limit_gh_ops_per_minute
    log.debug("Sleeping for #{sleep_time.round(2)}s to honor rate-limit")
    sleep(sleep_time)
  end
end

# Fetch PR and Issue stats from GitHub in a single API call
def get_pr_and_issue_stats(client, options)
  repo = "#{options[:org]}/#{options[:repo]}"
  cutoff_date = Date.today - options[:days]
  pr_stats = {
    open: 0,
    closed: 0,
    total_close_time: 0.0,
    oldest_open: nil,
    oldest_open_days: 0,
    oldest_open_last_activity: 0,
    stale_count: 0,
    opened_this_period: 0,
  }
  issue_stats = {
    open: 0,
    closed: 0,
    total_close_time: 0.0,
    oldest_open: nil,
    oldest_open_days: 0,
    oldest_open_last_activity: 0,
    stale_count: 0,
    opened_this_period: 0,
  }
  prs = { open: [], closed: [] }
  issues = { open: [], closed: [] }
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

      log.debug(
        "Checking item: #{is_pr ? 'PR' : 'Issue'}, " +
        "Created at #{created_date}, Closed at #{closed_date || 'N/A'}",
      )

      stats = is_pr ? pr_stats : issue_stats
      list = is_pr ? prs : issues

      # we count open as open and not waiting on contributor
      if closed_date.nil? && !labels.include?('Status: Waiting on Contributor')
        if stats[:oldest_open].nil? || created_date < stats[:oldest_open]
          stats[:oldest_open] = created_date
          stats[:oldest_open_days] = days_open
          stats[:oldest_open_last_activity] = days_since_last_activity
        end

        stats[:stale_count] += 1 if last_comment_date < stale_cutoff
        stats[:open] += 1
        # Count those opened recently separately
        if created_date >= cutoff_date
          stats[:opened_this_period] += 1
          list[:open] << item
          all_items_before_cutoff = false
        end
      end

      # Only count as closed if it was actually closed within the cutoff window
      next unless closed_date && closed_date >= cutoff_date

      # if it's a PR make sure it was closed by merging
      next unless !is_pr || item.pull_request.merged_at

      # anything closed this week counts as closed regardless of when it
      # was opened
      list[:closed] << item
      stats[:closed] += 1
      stats[:total_close_time] += (item.closed_at - item.created_at) / 3600.0
      all_items_before_cutoff = false
    end

    page += 1
    break if all_items_before_cutoff
  end
  pr_stats[:avg_time_to_close_hours] =
    if pr_stats[:closed].zero?
      0
    else
      pr_stats[:total_close_time] / pr_stats[:closed]
    end
  issue_stats[:avg_time_to_close_hours] =
    if issue_stats[:closed].zero?
      0
    else
      issue_stats[:total_close_time] / issue_stats[:closed]
    end
  { pr: pr_stats, issue: issue_stats, pr_list: prs, issue_list: issues }
end

def get_failed_tests_from_ci(client, settings)
  repo = "#{settings[:org]}/#{settings[:repo]}"
  cutoff_date = Date.today - settings[:days]
  today = Date.today
  failed_tests = {}
  branches_to_check = settings[:branches]
  processed_branches = if branches_to_check.is_a?(String)
                         branches_to_check.split(',').map(&:strip)
                       else
                         Array(branches_to_check).map(&:strip)
                       end
  processed_branches.each { |b| failed_tests[b] = {} }

  processed_branches.each do |branch|
    log.debug("Checking workflow runs for #{repo}, branch: #{branch}")
    begin
      workflows = client.workflows(repo).workflows
      rate_limited_sleep
      workflows.each do |workflow|
        log.debug("Workflow: #{workflow.name}")
        workflow_runs = []
        page = 1
        loop do
          log.debug("  Acquiring page #{page}")
          runs = client.workflow_runs(
            repo, workflow.id, branch:, status: 'completed', per_page: 100,
            page:
          )
          rate_limited_sleep

          break if runs.workflow_runs.empty?

          workflow_runs.concat(runs.workflow_runs)

          break if workflow_runs.last.created_at.to_date < cutoff_date

          page += 1
        end

        workflow_runs.sort_by!(&:created_at).reverse!
        last_failure_date = {}
        workflow_runs.each do |run|
          log.debug("  Looking at workflow run #{run.id}")
          run_date = run.created_at.to_date
          next if run_date < cutoff_date

          jobs = client.workflow_run_jobs(repo, run.id, per_page: 100).jobs
          rate_limited_sleep

          jobs.each do |job|
            log.debug("    Looking at job #{job.name} [#{job.conclusion}]")
            job_name_key = "#{workflow.name} / #{job.name}"
            if job.conclusion == 'failure'
              failed_tests[branch][job_name_key] ||= Set.new
              failed_tests[branch][job_name_key] << run_date
              last_failure_date[job_name_key] = run_date
            elsif job.conclusion == 'success'
              if last_failure_date[job_name_key] &&
                 last_failure_date[job_name_key] <= run_date
                last_failure_date.delete(job_name_key)
              end
            end
          end
        end
        last_failure_date.each do |job_key, last_fail_date|
          (last_fail_date + 1..today).each do |date|
            (failed_tests[branch][job_key] ||= Set.new) << date
          end
        end
      end
    rescue Octokit::NotFound => e
      log.warn(
        "Workflow API returned 404 for #{repo} branch " +
        "#{branch}: #{e.message}.",
      )
    rescue Octokit::Error, StandardError => e
      log.error(
        "Error processing branch #{branch} for repo " +
        "#{repo}: #{e.message}",
      )
      log.debug(e.backtrace.join("\n"))
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
    "    * Open #{type_plural}: #{stats[:open]} " +
    "(#{include_list ? 'listing ' : ''}#{stats[:opened_this_period]} " +
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
      "    * Oldest Open #{type}: #{stats[:oldest_open]} " +
      "(#{stats[:oldest_open_days]} days open, last activity " +
      "#{stats[:oldest_open_last_activity]} days ago)",
    )
  end
  log.info(
    "    * Stale #{type} (>30 days without comment): #{stats[:stale_count]}",
  )
  avg_time = stats[:avg_time_to_close_hours]
  avg_time_str =
    if avg_time > 24
      "#{(avg_time / 24).round(2)} days"
    else
      "#{avg_time.round(2)} hours"
    end
  log.info("    * Avg Time to Close #{type_plural}: #{avg_time_str}")
end

def print_ci_status(test_failures, _options)
  log.info("\n* CI Stats:")
  test_failures.each do |branch, jobs|
    line = "    * Branch: `#{branch}`"
    if jobs.empty?
      log.info(line + ': No job failures found! :tada:')
    else
      log.info(line + ' has the following failures:')
      jobs.sort.each do |job, dates|
        log.info("        * #{job}: #{dates.size} days")
      end
    end
  end
end

def parse_options # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  options = {}
  valid_modes = %w{ci pr issue all}
  OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

    opts.on(
      '--branches BRANCHES',
      Array,
      'Comma-separated list of branches',
    ) do |v|
      options[:default_branches] = v
    end

    opts.on(
      '-c FILE',
      '--config FILE_PATH',
      String,
      'Config file to load. [default: will look for `ci_stats_config.rb` ' +
      'in `./`, `~/.config/oss_stats`, and `/etc`]',
    ) do |c|
      options[:config] = c
    end

    opts.on(
      '-d DAYS',
      '--days DAYS',
      Integer,
      'Number of days to analyze',
    ) do |v|
      options[:default_days] = v
    end

    opts.on(
      '--ci-timeout TIMEOUT',
      Integer,
      'Timeout for CI processing in seconds',
    ) do |v|
      options[:ci_timeout] = v
    end

    opts.on(
      '--github-token TOKEN',
      'GitHub personal access token',
    ) do |v|
      options[:github_token] = v
    end

    opts.on(
      '--github-api-endpoint ENDPOINT',
      String,
      'GitHub API endpoint',
    ) do |v|
      options[:github_api_endpoint] = v
    end

    opts.on(
      '--include-list',
      'Include list of relevant PRs/Issues (default: false)',
    ) do
      options[:include_list] = true
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
      %i{debug info warn error fatal},
      'Set logging level to LEVEL. [default: info]',
    ) do |level|
      options[:log_level] = level
    end

    opts.on(
      '--mode MODE',
      Array,
      'Comma-separated list of modes: ci,issue,pr, or all (default: all)',
    ) do |v|
      invalid_modes = v.map(&:downcase) - valid_modes
      unless invalid_modes.empty?
        raise OptionParser::InvalidArgument,
          "Invalid mode(s): #{invalid_modes.join(', ')}." +
          "Valid modes are: #{valid_modes.join(', ')}"
      end
      options[:mode] = v.map(&:downcase)
    end

    opts.on(
      '--org ORG_NAME',
      String,
      'GitHub organization name',
    ) do |v|
      options[:org] = v
    end

    opts.on(
      '--repo REPO_NAME',
      String,
      'GitHub repository name',
    ) do |v|
      options[:repo] = v
    end
  end.parse!
  log.level = options[:log_level] if options[:log_level]

  # Determine config file and load
  config_to_load = options[:config] || OssStats::CiStatsConfig.config_file
  if config_to_load && File.exist?(config_to_load)
    expanded_config = File.expand_path(config_to_load)
    log.info("Loaded configuration from: #{expanded_config}")
    OssStats::CiStatsConfig.from_file(expanded_config)
  end
  OssStats::CiStatsConfig.merge!(options)
  log.level = OssStats::CiStatsConfig.log_level

  if options[:org] && options[:repo]
    log.debug('Overwriting any config organizations with CLI opts')
    repo_config =
      OssStats::CiStatsConfig.organizations.fetch(
        options[:org], {}
      ).fetch('repositories', {}).fetch(options[:repo], {})
    OssStats::CiStatsConfig.organizations = {
      options[:org] => {
        'repositories' => {
          options[:repo] => repo_config,
        },
      },
    }
  elsif options[:org] || options[:repo]
    log.fatal(
      'Error: Both --org and --repo must be specified if either is used. ' +
      'Exiting.',
    )
    exit 1
  end
end

def main
  parse_options

  token = get_github_token!(OssStats::CiStatsConfig)

  # Initialize Octokit::Client using the token now stored in config
  client = Octokit::Client.new(
    access_token: token,
    api_endpoint: OssStats::CiStatsConfig.github_api_endpoint,
  )

  get_effective_settings =
    lambda do |org, repo, org_file_conf = {}, repo_file_conf = {}|
      settings = { org:, repo: }
      settings[:days] = repo_file_conf['days'] ||
                        org_file_conf['default_days'] ||
                        OssStats::CiStatsConfig.default_days
      settings[:branches] = repo_file_conf['branches'] ||
                            org_file_conf['default_branches'] ||
                            OssStats::CiStatsConfig.default_branches
      settings[:branches] = Array(
        if settings[:branches].is_a?(String)
          settings[:branches].split(',').map(&:strip)
        else
          settings[:branches]
        end,
      )
      settings
    end

  mode = OssStats::CiStatsConfig.mode
  mode = %w{ci pr issue} if mode.include?('all')
  repos_to_process = []

  if OssStats::CiStatsConfig.organizations.nil? ||
     OssStats::CiStatsConfig.organizations.empty?
    log.warn('No organizations/repositories process. Exiting.')
    exit 0
  end

  OssStats::CiStatsConfig.organizations.each do |org_name, org_config|
    log.debug("Building config for org #{org_name}")
    repos = org_config['repositories'] || {}
    repos.each do |repo_name, repo_config|
      log.debug("Building config for repo #{repo_name}")
      repos_to_process << get_effective_settings.call(
        org_name, repo_name, org_config, repo_config
      )
    end
  end

  if repos_to_process.empty?
    log.warn('No organizations/repositories process. Exiting.')
    exit 0
  end

  repos_to_process.each do |settings|
    url = "https://github.com/#{settings[:org]}/#{settings[:repo]}"
    log.info(
      "\n*_[#{settings[:org]}/#{settings[:repo]}](#{url}) Stats " +
      "(Last #{settings[:days]} days)_*",
    )
    if %w{all pr issue}.any? { |m| mode.include?(m) }
      stats = get_pr_and_issue_stats(client, settings)
      %w{PR Issue}.each do |type|
        next unless mode.include?(type.downcase)
        print_pr_or_issue_stats(
          stats, type, OssStats::CiStatsConfig.include_list
        )
      end
    end

    next unless mode.include?('ci')
    test_failures = get_failed_tests_from_ci(client, settings)
    print_ci_status(test_failures || {}, {})
  end
end

main if __FILE__ == $PROGRAM_NAME
