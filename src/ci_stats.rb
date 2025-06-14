#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'base64'
require 'set'

require_relative 'lib/oss_stats/log'
require_relative 'lib/oss_stats/ci_stats_config'
require_relative 'lib/oss_stats/github_token'
require_relative 'lib/oss_stats/buildkite_token'
require_relative 'lib/oss_stats/buildkite_client'

def rate_limited_sleep
  limit_gh_ops_per_minute = OssStats::CiStatsConfig.limit_gh_ops_per_minute
  if limit_gh_ops_per_minute&.positive?
    sleep_time = 60.0 / limit_gh_ops_per_minute
    log.debug("Sleeping for #{sleep_time.round(2)}s to honor rate-limit")
    sleep(sleep_time)
  end
end

# Fetches and processes Pull Request and Issue statistics for a given repository
# from GitHub within a specified number of days.
#
# @param client [Octokit::Client] The Octokit client for GitHub API interaction.
# @param options [Hash] A hash containing options like :org, :repo, and :days.
# @return [Hash] A hash containing processed PR and issue statistics and lists.
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

# Fetches failed test results from CI systems (GitHub Actions and Buildkite)
# for a given repository and branches.
#
# For GitHub Actions, it queries workflow runs and their associated jobs.
# For Buildkite, it parses the README for a Buildkite badge, then queries the
# Buildkite API for pipeline builds and jobs.
#
# It implements logic to track ongoing failures: if a job fails and is not
# subsequently fixed by a successful run on the same branch, it's considered
# to be continuously failing.
#
# @param client [Octokit::Client] The Octokit client for GitHub API interaction.
# @param settings [Hash] A hash containing settings like :org, :repo, :days, and
#   :branches.
# @return [Hash] A hash where keys are branch names, and values are hashes of
#   job names to a Set of dates the job failed.
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

  # Buildkite CI
  log.debug("Checking for Buildkite integration for #{repo}")
  begin
    readme_content = Base64.decode64(client.readme(repo).content)
    rate_limited_sleep
    # Regex to find Buildkite badge markdown and capture the pipeline slug
    # from the link URL. Example:
    # [![Build Status](badge.svg)](https://buildkite.com/org/pipeline)
    # Captures:
    # 1: Full URL (https://buildkite.com/org/pipeline)
    # 2: Org slug (org)
    # 3: Pipeline slug (pipeline)
    buildkite_badge_regex =
      %r{\)\]\((https://buildkite\.com\/([^\/]+)\/([^\/\)]+))\)}
    match = readme_content.match(buildkite_badge_regex)

    if match
      buildkite_org_slug = match[2]
      pipeline_slug_from_regex = match[3]
      # Pipeline slug from regex might be "org/pipeline" or just "pipeline".
      # The BuildkiteClient expects only the pipeline name part, as it uses its
      # own organization slug during initialization.
      pipeline_name_only = pipeline_slug_from_regex.split('/').last

      log.debug(
        'Found Buildkite pipeline: ' +
        "#{buildkite_org_slug}/#{pipeline_name_only} in README for #{repo}",
      )

      buildkite_token = get_buildkite_token!(OssStats::CiStatsConfig)
      buildkite_client = OssStats::BuildkiteClient.new(
        buildkite_token, buildkite_org_slug
      )
      from_date = Date.today - settings[:days]
      today = Date.today

      processed_branches.each do |branch|
        log.debug(
          'Fetching Buildkite builds for ' +
          "#{buildkite_org_slug}/#{pipeline_name_only}, branch: #{branch}",
        )
        api_builds = buildkite_client.get_pipeline_builds(
          pipeline_name_only, nil, from_date, today
        )

        # Sort builds by createdAt timestamp to process chronologically
        # rubocop:disable Style/MultilineBlockChain
        sorted_builds = api_builds.select do |b_edge|
          b_edge&.dig('node', 'createdAt')
        end.sort_by { |b_edge| DateTime.parse(b_edge['node']['createdAt']) }
        # rubocop:enable Style/MultilineBlockChain

        last_failure_date_bk = {}

        sorted_builds.each do |build_edge|
          build = build_edge['node']
          begin
            build_date = DateTime.parse(build['createdAt']).to_date
          rescue ArgumentError, TypeError
            log.warn(
              "Invalid createdAt date for build in #{pipeline_name_only}: " +
              "'#{build['createdAt']}'. Skipping this build.",
            )
            next
          end

          # Ensure build is within the processing date range
          next if build_date < from_date

          next unless build['state']
          job_key = "[BK] #{buildkite_org_slug}/#{pipeline_name_only}"

          if build['state'] == 'FAILED'
            (failed_tests[branch][job_key] ||= Set.new) << build_date
            log.debug("Marking #{job_key} as failed (#{build_date})")
            last_failure_date_bk[job_key] = build_date
          elsif build['state'] == 'PASSED'
            # If a job passes, and it had a recorded failure on or before this
            # build's date, clear it from ongoing failures.
            if last_failure_date_bk[job_key] &&
               last_failure_date_bk[job_key] <= build_date
              log.debug("Unmarking #{job_key} as failed (#{build_date})")
              last_failure_date_bk.delete(job_key)
            end
          end
        end

        # Propagate ongoing failures: if a job failed and didn't pass later,
        # mark all subsequent days until today as failed.
        last_failure_date_bk.each do |job_key, last_fail_date|
          (last_fail_date + 1..today).each do |date|
            (failed_tests[branch][job_key] ||= Set.new) << date
          end
        end
      end
    elsif readme_content # Readme exists but no badge found
      log.debug("No Buildkite badge found in README for #{repo}")
    end
  rescue Octokit::NotFound
    log.warn("README.md not found for repo #{repo}. Skipping Buildkite check.")
  rescue StandardError => e
    log.error("Error during Buildkite integration for #{repo}: #{e.message}")
    log.debug(e.backtrace.join("\n"))
  end

  # GitHub Actions CI
  processed_branches.each do |branch|
    log.debug(
      "Checking GitHub Actions workflow runs for #{repo}, branch: #{branch}",
    )
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

# Prints formatted Pull Request or Issue statistics.
#
# @param data [Hash] The hash containing PR/Issue stats and lists from
#   `get_pr_and_issue_stats`.
# @param type [String] The type of item to print ("PR" or "Issue").
# @param include_list [Boolean] Whether to include lists of individual
#   PRs/Issues.
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
  if include_list && stats[:opened_this_period].positive?
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
      "(#{stats[:oldest_open_days]} days open, " +
      "last activity #{stats[:oldest_open_last_activity]} days ago)",
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

# Prints formatted CI status (failed tests).
#
# @param test_failures [Hash] The hash of test failures from
#   `get_failed_tests_from_ci`.
# @param _options [Hash] Additional options (currently unused).
def print_ci_status(test_failures)
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
      '--buildkite-token TOKEN',
      String,
      'Buildkite API token',
    ) do |v|
      options[:buildkite_token] = v
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

  # Set log level from CLI options first if provided
  log.level = options[:log_level] if options[:log_level]

  # Determine config file path.
  config_file_to_load = options[:config] || OssStats::CiStatsConfig.config_file

  # Load config from file if found
  if config_file_to_load && File.exist?(config_file_to_load)
    expanded_config_path = File.expand_path(config_file_to_load)
    log.info("Loaded configuration from: #{expanded_config_path}")
    OssStats::CiStatsConfig.from_file(expanded_config_path)
  elsif options[:config] # Config file specified via CLI but not found
    log.fatal("Specified config file '#{options[:config]}' not found.")
    exit 1
  end

  # Merge CLI options into the configuration. CLI options take precedence.
  OssStats::CiStatsConfig.merge!(options)

  # Set final log level from potentially merged config
  log.level = OssStats::CiStatsConfig.log_level

  # Handle org/repo specified via CLI: overrides any config file orgs/repos.
  if options[:org] && options[:repo]
    log.debug('Using organization and repository from command line arguments.')
    # Fetch existing repo config to preserve specific settings if any,
    # otherwise, it will be an empty hash.
    org_settings =
      OssStats::CiStatsConfig.organizations.fetch(options[:org], {})
    repo_settings =
      org_settings.fetch('repositories', {}).fetch(options[:repo], {})

    OssStats::CiStatsConfig.organizations = {
      options[:org] => {
        'repositories' => { options[:repo] => repo_settings },
      },
    }
  elsif options[:org] || options[:repo] # Only one of org/repo specified
    log.fatal(
      'Error: Both --org and --repo must be specified if either is used.',
    )
    exit 1
  end
end

def main
  parse_options # Parse CLI options and load config

  github_token = get_github_token!(OssStats::CiStatsConfig)
  client = Octokit::Client.new(
    access_token: github_token,
    api_endpoint: OssStats::CiStatsConfig.github_api_endpoint,
  )

  # Lambda to construct effective settings for a repository by merging
  # global, org-level, and repo-level configurations.
  get_effective_repo_settings =
    lambda do |org, repo_name, org_conf = {}, repo_conf = {}|
      effective = { org:, repo: repo_name }
      effective[:days] = repo_conf['days'] ||
                         org_conf['default_days'] ||
                         OssStats::CiStatsConfig.default_days
      branches_setting = repo_conf['branches'] ||
                         org_conf['default_branches'] ||
                         OssStats::CiStatsConfig.default_branches
      effective[:branches] = if branches_setting.is_a?(String)
                               branches_setting.split(',').map(&:strip)
                             else
                               Array(branches_setting).map(&:strip)
                             end
      effective
    end

  # Determine which modes of operation are active (ci, pr, issue)
  mode = OssStats::CiStatsConfig.mode
  mode = %w{ci pr issue} if mode.include?('all')

  # Prepare list of repositories to process based on configuration
  repos_to_process = []
  if OssStats::CiStatsConfig.organizations.nil? ||
     OssStats::CiStatsConfig.organizations.empty?
    log.warn('No organizations or repositories configured to process. Exiting.')
    exit 0
  end

  OssStats::CiStatsConfig.organizations.each do |org_name, org_level_config|
    log.debug("Processing configuration for organization: #{org_name}")
    repos = org_level_config['repositories'] || {}
    repos.each do |repo_name, repo_level_config|
      log.debug("Processing configuration for repository: #{repo_name}")
      repos_to_process << get_effective_repo_settings.call(
        org_name, repo_name, org_level_config, repo_level_config
      )
    end
  end

  if repos_to_process.empty?
    log.info(
      'No repositories found to process after evaluating configurations.',
    )
    exit 0
  end

  # Process each configured repository
  repos_to_process.each do |settings|
    repo_full_name = "#{settings[:org]}/#{settings[:repo]}"
    repo_url = "https://github.com/#{repo_full_name}"
    log.info(
      "\n*_[#{repo_full_name}](#{repo_url}) Stats " +
      "(Last #{settings[:days]} days)_*",
    )

    # Fetch and print PR and Issue stats if PR or Issue mode is active
    if %w{pr issue}.any? { |m| mode.include?(m) }
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
    print_ci_status(test_failures)
  end
end

main if __FILE__ == $PROGRAM_NAME
