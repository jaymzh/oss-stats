#!/usr/bin/env ruby

require 'base64'
require 'date'
require 'deep_merge'
require 'octokit'
require 'optparse'
require 'set'
require 'yaml'

require_relative '../lib/oss_stats/buildkite_client'
require_relative '../lib/oss_stats/buildkite_token'
require_relative '../lib/oss_stats/config/repo_stats'
require_relative '../lib/oss_stats/github_token'
require_relative '../lib/oss_stats/log'

def rate_limited_sleep
  limit_gh_ops_per_minute = OssStats::Config::RepoStats.limit_gh_ops_per_minute
  if limit_gh_ops_per_minute&.positive?
    sleep_time = 60.0 / limit_gh_ops_per_minute
    log.debug("Sleeping for #{sleep_time.round(2)}s to honor rate-limit")
    sleep(sleep_time)
  end
end

# Fetches and processes Pull Request and Issue statistics for a given repository
# from GitHub within a specified number of days.
#
# @param gh_client [Octokit::Client] The Octokit client for GitHub API
#   interaction.
# @param options [Hash] A hash containing options like :org, :repo, and :days.
# @return [Hash] A hash containing processed PR and issue statistics and lists.
def get_pr_and_issue_stats(gh_client, options)
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
    items = gh_client.issues(repo, state: 'all', per_page: 100, page:)
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

def pipelines_from_readme(readme, bk_client)
  pipelines = []
  # Regex to find Buildkite badge markdown and capture the pipeline slug
  # from the link URL. Example:
  # [![Build Status](badge.svg)](https://buildkite.com/org/pipeline)
  # Captures:
  # 1: Full URL (https://buildkite.com/org/pipeline)
  # 2: Org slug (org)
  # 3: Pipeline slug (pipeline)
  buildkite_badge_regex =
    %r{\)\]\((https://buildkite\.com\/([^\/]+)\/([^\/\)]+))\)}
  matches = readme.scan(buildkite_badge_regex)
  if matches.length.zero?
    log.debug('no BK pipelines found in readme')
    return pipelines
  end

  matches.each do |match|
    buildkite_org = match[1]
    pipeline = match[2]
    pk = bk_client.get_pipeline(buildkite_org, pipeline)
    pipelines << {
      pipeline:,
      org: buildkite_org,
      url: pk['url'],
    }

    log.debug(
      "Found Buildkite pipeline: #{buildkite_org}/#{pipeline} in README",
    )
  end

  pipelines
end

def get_bk_failed_tests(
  gh_client, bk_client, repo, bk_pipelines_by_repo, settings, branches
)
  failed_tests = {}
  pipelines_to_check = Set.new
  pipelines_to_check.merge(
    bk_pipelines_by_repo.fetch("https://github.com/#{repo}", []).map do |x|
      {
        org: OssStats::Config::RepoStats.buildkite_org,
        pipeline: x[:slug],
        url: x[:url],
      }
    end,
  )

  begin
    readme = Base64.decode64(gh_client.readme(repo).content)
    rate_limited_sleep

    pipelines_to_check.merge(pipelines_from_readme(readme, bk_client))
  rescue Octokit::NotFound
    log.warn(
      "README.md not found for repo #{repo}. Skipping Buildkite check.",
    )
  end

  from_date = Date.today - settings[:days]
  today = Date.today
  pipelines_to_check.each do |pl|
    branches.each do |branch|
      log.debug(
        "Fetching Buildkite builds for #{pl}, branch: #{branch}",
      )
      api_builds = bk_client.get_pipeline_builds(
        pl[:org], pl[:pipeline], from_date, today, branch
      )
      if api_builds.length.zero?
        log.debug("No builds for #{pl} on #{branch}")
        next
      end

      failed_tests[branch] ||= {}

      # Sort builds by createdAt timestamp to process chronologically
      # rubocop:disable Style/MultilineBlockChain
      sorted_builds = api_builds.select do |b_edge|
        b_edge&.dig('node', 'createdAt')
      end.sort_by { |b_edge| DateTime.parse(b_edge['node']['createdAt']) }
      # rubocop:enable Style/MultilineBlockChain

      last_failure_date_bk = {}

      sorted_builds.each do |build_edge|
        build = build_edge['node']
        id = build['id']
        log.debug("Build #{id} for #{pl}")
        begin
          build_date = DateTime.parse(build['createdAt']).to_date
        rescue ArgumentError, TypeError
          log.warn(
            "Invalid createdAt date for build in #{pl}: " +
            "'#{build['createdAt']}'. Skipping this build.",
          )
          next
        end

        # Ensure build is within the processing date range
        if build_date < from_date
          log.debug('Build before time we care about, skipping')
          next
        end

        unless build['state']
          log.debug('no build state, skipping')
          next
        end
        job_key = "[BK] #{pl[:org]}/#{pl[:pipeline]}"

        if build['state'] == 'FAILED'
          # we link to the pipeline, not the specific build
          failed_tests[branch][job_key] ||= { url: pl[:url], dates: Set.new }
          failed_tests[branch][job_key][:dates] << build_date
          log.debug("Marking #{job_key} as failed (#{id} on #{build_date})")
          last_failure_date_bk[job_key] = build_date
        elsif build['state'] == 'PASSED'
          # If a job passes, and it had a recorded failure on or before this
          # build's date, clear it from ongoing failures.
          if last_failure_date_bk[job_key] &&
             last_failure_date_bk[job_key] <= build_date
            log.debug(
              "Unmarking #{job_key} as failed (#{id} on #{build_date})",
            )
            last_failure_date_bk.delete(job_key)
          else
            log.debug(
              "Ignoring #{job_key} success earlier than last failure" +
              " (#{id} on #{build_date})",
            )
          end
        else
          log.debug("State is #{build['state']}, ignoring")
        end
      end

      # Propagate ongoing failures: if a job failed and didn't pass later,
      # mark all subsequent days until today as failed.
      last_failure_date_bk.each do |job_key, last_fail_date|
        (last_fail_date + 1..today).each do |date|
          failed_tests[branch][job_key][:dates] << date
        end
      end
    end
  end

  failed_tests
rescue StandardError => e
  log.error("Error during Buildkite integration for #{repo}: #{e.message}")
  log.debug(e.backtrace.join("\n"))
  # we may have captured some, return what we got
  failed_tests
end

def get_gh_failed_tests(gh_client, repo, settings, branches)
  failed_tests = {}
  cutoff_date = Date.today - settings[:days]
  today = Date.today
  branches.each do |branch|
    log.debug(
      "Checking GitHub Actions workflow runs for #{repo}, branch: #{branch}",
    )
    failed_tests[branch] ||= {}
    workflows = gh_client.workflows(repo).workflows
    rate_limited_sleep
    workflows.each do |workflow|
      log.debug("Workflow: #{workflow.name}")
      workflow_runs = []
      page = 1
      loop do
        log.debug("  Acquiring page #{page}")
        runs = gh_client.workflow_runs(
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

        jobs = gh_client.workflow_run_jobs(repo, run.id, per_page: 100).jobs
        rate_limited_sleep

        jobs.each do |job|
          log.debug("    Looking at job #{job.name} [#{job.conclusion}]")
          job_name_key = "#{workflow.name} / #{job.name}"
          if job.conclusion == 'failure'
            log.debug("Marking #{job_name_key} as failed (#{run_date})")
            # we want to link to the _workflow_ on the relevant branch.
            # If we link to a job, it's only on that given run, which
            # isn't relevant to our reports, we want people to go see
            # the current status and all the passes and failures.
            #
            # However, the link to the workflow is to the file that defines it,
            # which is not what we want, but it's easy to munge.
            url = workflow.html_url.gsub("blob/#{branch}", 'actions')
            url << "?query=branch%3A#{branch}"
            failed_tests[branch][job_name_key] ||= {
              # link to the workflow, not this specific run
              url:,
              dates: Set.new,
            }
            failed_tests[branch][job_name_key][:dates] << run_date
            last_failure_date[job_name_key] = run_date
          elsif job.conclusion == 'success'
            if last_failure_date[job_name_key] &&
               last_failure_date[job_name_key] <= run_date
              log.debug("Unmarking #{job_name_key} as failed (#{run_date})")
              last_failure_date.delete(job_name_key)
            else
              log.debug(
                "Ignoring #{job_name_key} success early then last failure" +
                "(#{run_date})",
              )
            end
          end
        end
      end
      last_failure_date.each do |job_key, last_fail_date|
        (last_fail_date + 1..today).each do |date|
          failed_tests[branch][job_key][:dates] << date
        end
      end
    end
  end

  failed_tests
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
# @param gh_client [Octokit::Client] The Octokit client for GitHub API
#   interaction.
# @param bk_client [BuildkiteClient] A buildkite client
# @param settings [Hash] A hash containing settings like :org, :repo, :days, and
#   :branches.
# @param bk_piplines_by_rep [Hash] A hash of repo -> list of BK pipelines
# @return [Hash] A hash where keys are branch names, and values are hashes of
#   job names to a Set of dates the job failed.
def get_failed_tests_from_ci(
  gh_client, bk_client, settings, bk_pipelines_by_repo
)
  repo = "#{settings[:org]}/#{settings[:repo]}"
  branches_to_check = settings[:branches]
  processed_branches = if branches_to_check.is_a?(String)
                         branches_to_check.split(',').map(&:strip)
                       else
                         Array(branches_to_check).map(&:strip)
                       end

  failed_tests = get_gh_failed_tests(
    gh_client, repo, settings, processed_branches
  )

  if bk_client
    failed_tests.deep_merge!(
      get_bk_failed_tests(
        gh_client,
        bk_client,
        repo,
        bk_pipelines_by_repo,
        settings,
        processed_branches,
      ),
    )
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
      if OssStats::Config::RepoStats.no_links
        log.info(
          "        * #{item.title} (##{item.number}) - @#{item.user.login}",
        )
      else
        log.info(
          "        * [#{item.title} (##{item.number})](#{item.html_url}) " +
          "- @#{item.user.login}",
        )
      end
    end
  end
  log.info(
    "    * Open #{type_plural}: #{stats[:open]} " +
    "(#{include_list ? 'listing ' : ''}#{stats[:opened_this_period]} " +
    'opened this period)',
  )
  if include_list && stats[:opened_this_period].positive?
    list[:open].each do |item|
      if OssStats::Config::RepoStats.no_links
        log.info(
          "        * #{item.title} (##{item.number}) - @#{item.user.login}",
        )
      else
        log.info(
          "        * [#{item.title} (##{item.number})](#{item.html_url}) " +
          "- @#{item.user.login}",
        )
      end
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
      jobs.sort.each do |job_name, job_data|
        if OssStats::Config::RepoStats.no_links
          log.info("        * #{job_name}: #{job_data[:dates].size} days")
        else
          log.info(
            "        * [#{job_name}](#{job_data[:url]}):" +
            " #{job_data[:dates].size} days",
          )
        end
      end
    end
  end
end

def parse_options
  options = {}
  valid_modes = %w{ci pr issue all}
  OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

    opts.on(
      '--branches BRANCHES',
      Array,
      'Comma-separated list of branches',
    ) { |v| options[:default_branches] = v }

    opts.on(
      '--buildkite-token TOKEN',
      String,
      'Buildkite API token',
    ) { |v| options[:buildkite_token] = v }

    opts.on(
      '--buildkite-org ORG',
      String,
      'Buildkite org to find pipelines in. If specified any pipeline in that' +
        ' org associated with any repos we report on will be included.',
    ) { |v| options[:buildkite_org] = v }

    opts.on(
      '-c FILE',
      '--config FILE_PATH',
      String,
      'Config file to load. [default: will look for `repo_stats_config.rb`' +
        ' in `./`, `~/.config/oss_stats`, and `/etc`]',
    ) { |c| options[:config] = c }

    opts.on(
      '-d DAYS',
      '--days DAYS',
      Integer,
      'Number of days to analyze. Overrides specific org or repo configs',
    ) { |v| options[:days] = v }

    opts.on(
      '-D DAYS',
      '--default-days DAYS',
      Integer,
      'Default number of days to analyze. Will be overriden by specific org' +
        ' or repo configs',
    ) { |v| options[:default_days] = v }

    opts.on(
      '--ci-timeout TIMEOUT',
      Integer,
      'Timeout for CI processing in seconds',
    ) { |v| options[:ci_timeout] = v }

    opts.on(
      '--github-api-endpoint ENDPOINT',
      String,
      'GitHub API endpoint',
    ) { |v| options[:github_api_endpoint] = v }

    opts.on(
      '--github-org ORG_NAME',
      String,
      'GitHub organization name',
    ) { |v| options[:github_org] = v }

    opts.on(
      '--github-repo REPO_NAME',
      String,
      'GitHub repository name',
    ) { |v| options[:github_repo] = v }

    opts.on(
      '--github-token TOKEN',
      'GitHub personal access token',
    ) { |v| options[:gh_token] = v }

    opts.on(
      '--include-list',
      'Include list of relevant PRs/Issues (default: false)',
    ) { options[:include_list] = true }

    opts.on(
      '--limit-gh-ops-per-minute RATE',
      Float,
      'Rate limit GitHub API operations to this number per minute',
    ) { |v| options[:limit_gh_ops_per_minute] = v }

    opts.on(
      '-l LEVEL',
      '--log-level LEVEL',
      %i{trace debug info warn error fatal},
      'Set logging level to LEVEL. [default: info]',
    ) { |level| options[:log_level] = level }

    opts.on(
      '--no-links',
      'Disable Markdown links in the output (default: false)',
    ) { options[:no_links] = true }

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
  end.parse!

  # Set log level from CLI options first if provided
  log.level = options[:log_level] if options[:log_level]
  config = OssStats::Config::RepoStats

  # Determine config file path.
  config_file_to_load = options[:config] || config.config_file

  # Load config from file if found
  if config_file_to_load && File.exist?(config_file_to_load)
    expanded_config_path = File.expand_path(config_file_to_load)
    log.info("Loaded configuration from: #{expanded_config_path}")
    config.from_file(expanded_config_path)
  elsif options[:config] # Config file specified via CLI but not found
    log.fatal("Specified config file '#{options[:config]}' not found.")
    exit 1
  end

  # Merge CLI options into the configuration. CLI options take precedence.
  config.merge!(options)

  # Set final log level from potentially merged config
  log.level = config.log_level

  if config.github_repo && !config.github_org
    raise ArgumentError, '--github-repo requires --github-org'
  end
end

# Construct effective settings for a repository by merging global, org-level,
# and repo-level configurations.
def get_effective_repo_settings(org, repo, org_conf = {}, repo_conf = {})
  effective = { org:, repo: }
  config = OssStats::Config::RepoStats

  # we allow somone to override days for the entire run (config.days) which
  # is different from the fallback (config.default_days)
  effective[:days] = config.days || repo_conf['days'] ||
                     org_conf['days'] || config.default_days
  branches_setting = repo_conf['branches'] ||
                     org_conf['branches'] || config.default_branches
  effective[:branches] =
    if branches_setting.is_a?(String)
      branches_setting.split(',').map(&:strip)
    else
      Array(branches_setting).map(&:strip)
    end
  effective
end

def determine_orgs_to_process
  config = OssStats::Config::RepoStats
  relevant_orgs = {}
  # Handle org/repo specified via CLI: overrides any config file orgs/repos.
  if config.github_org || config.github_repo
    # we already validated that if repo is set, so is org, so we can assume
    # org is set...
    if config.organizations[config.github_org]
      log.debug("Limiting config to #{config.github_org} org")
      relevant_orgs[config.github_org] =
        config.organizations[config.github_org].dup
    else
      log.debug(
        "Initialzing config structure for #{config.github_org} org requested" +
        ' on the command line, but not in config.',
      )
      relevant_orgs[config.github_org] = { 'repositories' => {} }
    end

    if config.github_repo
      if relevant_orgs[config.github_org]['repositories'][config.github_repo]
        log.debug("Limiting config to #{config.github_repo} repo")
        relevant_repo = relevant_orgs[config.github_org][
          'repositories'][config.github_repo]
        relevant_orgs[config.github_org]['repositories'] = {
          config.github_repo => relevant_repo,
        }
      else
        log.debug(
          "Initializing config structure for #{config.github_repo} repo" +
          ' requested on the command line, but not in config',
        )
        relevant_orgs[config.github_org]['repositories'] = {
          config.github_repo => {},
        }
      end
    end
  else
    relevant_orgs = config.organizations
  end
  relevant_orgs
end

def main
  parse_options
  config = OssStats::Config::RepoStats
  mode = config.mode
  mode = %w{ci pr issue} if mode.include?('all')

  organizations_to_process = determine_orgs_to_process

  # Prepare list of repositories to process based on configuration
  repos_to_process = []
  if organizations_to_process.empty?
    log.warn('No organizations or repositories configured to process. Exiting.')
    exit 0
  end

  # get tokens early so we fail if we're missing them
  gh_token = get_github_token!(config)
  gh_client = Octokit::Client.new(
    access_token: gh_token,
    api_endpoint: config.github_api_endpoint,
  )

  if mode.include?('ci') && config.buildkite_org
    bk_token = get_buildkite_token!(config)
    bk_client = OssStats::BuildkiteClient.new(bk_token)
    bk_pipelines_by_repo = bk_client.pipelines_by_repo(config.buildkite_org)
  end

  organizations_to_process.each do |org_name, org_level_config|
    log.debug("Processing configuration for organization: #{org_name}")
    repos = org_level_config['repositories'] || {}
    repos.each do |repo_name, repo_level_config|
      log.debug("Processing configuration for repository: #{repo_name}")
      repos_to_process << get_effective_repo_settings(
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
    if OssStats::Config::RepoStats.no_links
      log.info(
        "\n* #{repo_full_name} Stats (Last #{settings[:days]} days) *",
      )
    else
      log.info(
        "\n*_[#{repo_full_name}](#{repo_url}) Stats " +
        "(Last #{settings[:days]} days)_*",
      )
    end

    # Fetch and print PR and Issue stats if PR or Issue mode is active
    if %w{pr issue}.any? { |m| mode.include?(m) }
      stats = get_pr_and_issue_stats(gh_client, settings)
      %w{PR Issue}.each do |type|
        next unless mode.include?(type.downcase)
        print_pr_or_issue_stats(stats, type, config.include_list)
      end
    end

    next unless mode.include?('ci')
    test_failures = get_failed_tests_from_ci(
      gh_client, bk_client, settings, bk_pipelines_by_repo
    )
    print_ci_status(test_failures)
  end
end

main if __FILE__ == $PROGRAM_NAME
