#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'set'

require_relative 'lib/oss_stats/log'
require_relative 'lib/oss_stats/ci_stats_config'
require_relative 'lib/oss_stats/github_token'
require_relative 'lib/oss_stats/buildkite_client'
require_relative 'lib/oss_stats/buildkite_token'

def rate_limited_sleep
  limit = OssStats::CiStatsConfig.limit_gh_ops_per_minute
  if limit&.positive?
    sleep_time = 60.0 / limit
    log.debug("Sleeping for #{sleep_time.round(2)}s to honor rate-limit")
    sleep(sleep_time)
  end
end

# Fetch PR and Issue stats from GitHub in a single API call
def get_pr_and_issue_stats(client, options) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  repo = "#{options[:org]}/#{options[:repo]}"
  cutoff_date = Date.today - options[:days]
  pr_stats = {
    open: 0, closed: 0, total_close_time: 0.0, oldest_open: nil,
    oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0,
    opened_this_period: 0
  }
  issue_stats = {
    open: 0, closed: 0, total_close_time: 0.0, oldest_open: nil,
    oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0,
    opened_this_period: 0
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

      log.debug("Checking item: #{is_pr ? 'PR' : 'Issue'}, Created at " \
                "#{created_date}, Closed at #{closed_date || 'N/A'}")

      stats = is_pr ? pr_stats : issue_stats
      list = is_pr ? prs : issues

      # we count open as open and not waiting on contributor
      waiting_on_contrib = labels.include?('Status: Waiting on Contributor')
      if closed_date.nil? && !waiting_on_contrib
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
    pr_stats[:closed].zero? ? 0 : pr_stats[:total_close_time] / pr_stats[:closed]
  issue_stats[:avg_time_to_close_hours] =
    if issue_stats[:closed].zero?
      0
    else
      issue_stats[:total_close_time] / issue_stats[:closed]
    end
  { pr: pr_stats, issue: issue_stats, pr_list: prs, issue_list: issues }
end # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

# rubocop:disable Metrics/MethodLength, Metrics/AbcSize
# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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

  # Buildkite integration
  begin
    readme_content = client.readme(
      repo, accept: 'application/vnd.github.v3.raw'
    )
    rate_limited_sleep
    # Regex for Buildkite badges
    bk_badge_regex = %r{https://(?:badge|badges)\.buildkite\.com/([^/]+)/([^/]+)\.svg}
    match = readme_content.match(bk_badge_regex)

    if match
      org_slug = match[1]
      pipeline_slug = match[2]
      log.info("Found Buildkite pipeline: #{org_slug}/#{pipeline_slug}")

      # Assuming BuildkiteToken.token might take org_slug or similar
      buildkite_token = OssStats::BuildkiteToken.token(org_slug)

      if buildkite_token
        # Initialize with org_slug for BuildkiteClient if it needs it
        # The refactored client takes (token, org_slug)
        bk_client = OssStats::BuildkiteClient.new(buildkite_token, org_slug)
        processed_branches.each do |branch_name|
          log.debug("Fetching Buildkite builds for pipeline " \
                    "#{pipeline_slug}, branch: #{branch_name}, " \
                    "since: #{cutoff_date}")
          # get_pipeline_builds expects (short_pipeline_slug, branch, date)
          builds = bk_client.get_pipeline_builds(
            pipeline_slug, branch_name, cutoff_date
          )
          builds.each do |build|
            # Assuming build is a hash like { name: "...", date: "YYYY-MM-DD" }
            # and represents a failed job as per BuildkiteClient's transformation
            job_name = build[:name]
            created_at = Date.parse(build[:date]) # Date of failure

            # No need to check created_at < cutoff_date,
            # as get_pipeline_builds should handle the `since_date` filter.

            bk_job_key = "[Buildkite] #{org_slug}/#{pipeline_slug} / #{job_name}"
            # The structure from get_pipeline_builds is already failed jobs
            (failed_tests[branch_name][bk_job_key] ||= Set.new) << created_at
          end
        end
      else
        log.warn("Buildkite token not found for organization #{org_slug}. " \
                 "Skipping Buildkite stats.")
      end
    else
      log.info("No Buildkite badge found in README for #{repo}")
    end
  rescue Octokit::NotFound
    log.warn("README.md not found for #{repo}. Skipping Buildkite integration.")
  rescue StandardError => e
    log.error("Error during Buildkite integration for #{repo}: #{e.message}")
    log.debug(e.backtrace.join("\n"))
  end

  processed_branches.each do |branch| # GitHub Actions processing
    log.debug("Checking GitHub Actions workflow runs for #{repo}, " \
              "branch: #{branch}")
    begin
      workflows = client.workflows(repo).workflows
      rate_limited_sleep
      workflows.each do |workflow|
        log.debug("Workflow: #{workflow.name}")
        workflow_runs = []
        page = 1
        loop do # Paginate through workflow runs
          log.debug("  Acquiring page #{page}")
          runs_page = client.workflow_runs(
            repo, workflow.id, branch:, status: 'completed',
            per_page: 100, page:
          )
          rate_limited_sleep
          break if runs_page.workflow_runs.empty?
          workflow_runs.concat(runs_page.workflow_runs)
          break if workflow_runs.last.created_at.to_date < cutoff_date
          page += 1
        end

        workflow_runs.sort_by!(&:created_at).reverse!
        last_failure_date = {}
        workflow_runs.each do |run| # Process each run
          log.debug("  Looking at workflow run #{run.id}")
          run_date = run.created_at.to_date
          next if run_date < cutoff_date

          jobs = client.workflow_run_jobs(repo, run.id, per_page: 100).jobs
          rate_limited_sleep
          jobs.each do |job| # Process each job in the run
            log.debug("    Looking at job #{job.name} [#{job.conclusion}]")
            job_key = "[GitHub Actions] #{workflow.name} / #{job.name}"
            if job.conclusion == 'failure'
              (failed_tests[branch][job_key] ||= Set.new) << run_date
              last_failure_date[job_key] = run_date
            elsif job.conclusion == 'success'
              if last_failure_date.key?(job_key) &&
                 last_failure_date[job_key] &&
                 last_failure_date[job_key] <= run_date
                last_failure_date.delete(job_key)
              end
            end
          end
        end
        # Mark days from last failure to today as failed
        last_failure_date.each do |job_key, last_fail_date|
          (last_fail_date + 1..today).each do |date|
            (failed_tests[branch][job_key] ||= Set.new) << date
          end
        end
      end
    rescue Octokit::NotFound => e
      log.warn("Workflow API returned 404 for #{repo} branch #{branch}: " \
               "#{e.message}.")
    rescue Octokit::Error, StandardError => e
      log.error("Error processing branch #{branch} for repo #{repo}: " \
                "#{e.message}")
      log.debug(e.backtrace.join("\n"))
    end
  end
  failed_tests
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

def print_pr_or_issue_stats(data, type, include_list) # rubocop:disable Metrics/AbcSize
  stats = data[type.downcase.to_sym]
  list = data["#{type.downcase}_list".to_sym]
  type_plural = type + 's'
  log.info("\n* #{type} Stats:")
  log.info("    * Closed #{type_plural}: #{stats[:closed]}")
  if include_list
    list[:closed].each do |item|
      log.info("        * [#{item.title} (##{item.number})]" \
               "(#{item.html_url}) - @#{item.user.login}")
    end
  end
  opened_this_period_msg = if include_list
                             "listing #{stats[:opened_this_period]}"
                           else
                             stats[:opened_this_period].to_s
                           end
  log.info("    * Open #{type_plural}: #{stats[:open]} " \
           "(#{opened_this_period_msg} opened this period)")

  if include_list && stats[:opened_this_period].positive?
    list[:open].each do |item|
      log.info("        * [#{item.title} (##{item.number})]" \
               "(#{item.html_url}) - @#{item.user.login}")
    end
  end
  if stats[:oldest_open]
    log.info("    * Oldest Open #{type}: #{stats[:oldest_open]} " \
             "(#{stats[:oldest_open_days]} days open, last activity " \
             "#{stats[:oldest_open_last_activity]} days ago)")
  end
  log.info("    * Stale #{type} (>30 days without comment): " \
           "#{stats[:stale_count]}")
  avg_time = stats[:avg_time_to_close_hours]
  avg_time_str = if avg_time > 24
                   "#{(avg_time / 24).round(2)} days"
                 else
                   "#{avg_time.round(2)} hours"
                 end
  log.info("    * Avg Time to Close #{type_plural}: #{avg_time_str}")
end # rubocop:enable Metrics/AbcSize

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
  valid_modes = %w[ci pr issue all]
  OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

    opts.on('--branches BRANCHES', Array, 'Comma-separated list of branches') do |v|
      options[:default_branches] = v
    end

    opts.on(
      '-c FILE', '--config FILE_PATH', String,
      'Config file to load. [default: will look for `ci_stats_config.rb` ' \
      'in `./`, `~/.config/oss_stats`, and `/etc`]'
    ) { |c| options[:config] = c }

    opts.on('-d DAYS', '--days DAYS', Integer, 'Number of days to analyze') do |v|
      options[:default_days] = v
    end

    opts.on('--ci-timeout TIMEOUT', Integer,
            'Timeout for CI processing in seconds') do |v|
      options[:ci_timeout] = v
    end

    opts.on('--github-token TOKEN', 'GitHub personal access token') do |v|
      options[:github_token] = v
    end

    opts.on('--github-api-endpoint ENDPOINT', String, 'GitHub API endpoint') do |v|
      options[:github_api_endpoint] = v
    end

    opts.on('--include-list',
            'Include list of relevant PRs/Issues (default: false)') do
      options[:include_list] = true
    end

    opts.on('--limit-gh-ops-per-minute RATE', Float,
            'Rate limit GitHub API operations to this number per minute') do |v|
      options[:limit_gh_ops_per_minute] = v
    end

    opts.on('-l LEVEL', '--log-level LEVEL', %i[debug info warn error fatal],
            'Set logging level to LEVEL. [default: info]') do |level|
      options[:log_level] = level
    end

    opts.on(
      '--mode MODE', Array,
      'Comma-separated list of modes: ci,issue,pr, or all (default: all)'
    ) do |v|
      invalid_modes = v.map(&:downcase) - valid_modes
      unless invalid_modes.empty?
        raise OptionParser::InvalidArgument,
              "Invalid mode(s): #{invalid_modes.join(', ')}. " \
              "Valid modes are: #{valid_modes.join(', ')}"
      end
      options[:mode] = v.map(&:downcase)
    end

    opts.on('--org ORG_NAME', String, 'GitHub organization name') do |v|
      options[:org] = v
    end

    opts.on('--repo REPO_NAME', String, 'GitHub repository name') do |v|
      options[:repo] = v
    end
  end.parse!
  log.level = options[:log_level] if options[:log_level]

  # Determine config file and load
  config_path = options[:config] || OssStats::CiStatsConfig.config_file
  if config_path && File.exist?(config_path)
    expanded_config = File.expand_path(config_path)
    log.info("Loaded configuration from: #{expanded_config}")
    OssStats::CiStatsConfig.from_file(expanded_config)
  end
  OssStats::CiStatsConfig.merge!(options)
  log.level = OssStats::CiStatsConfig.log_level

  if options[:org] && options[:repo]
    log.debug('Overwriting any config organizations with CLI opts')
    repo_conf = OssStats::CiStatsConfig.organizations
                                     .fetch(options[:org], {})
                                     .fetch('repositories', {})
                                     .fetch(options[:repo], {})
    OssStats::CiStatsConfig.organizations = {
      options[:org] => { 'repositories' => { options[:repo] => repo_conf } }
    }
  elsif options[:org] || options[:repo]
    log.fatal('Error: Both --org and --repo must be specified if either ' \
              'is used. Exiting.')
    exit 1
  end
end # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

def main # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  parse_options

  token = get_github_token!(OssStats::CiStatsConfig)

  # Initialize Octokit::Client using the token now stored in config
  client = Octokit::Client.new(
    access_token: token,
    api_endpoint: OssStats::CiStatsConfig.github_api_endpoint
  )

  get_effective_settings = lambda do |org, repo, org_conf = {}, repo_conf = {}|
    settings = { org:, repo: }
    settings[:days] = repo_conf['days'] ||
                      org_conf['default_days'] ||
                      OssStats::CiStatsConfig.default_days
    settings[:branches] = repo_conf['branches'] ||
                          org_conf['default_branches'] ||
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
  mode = %w[ci pr issue] if mode.include?('all')
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
    log.info("\n*_[#{settings[:org]}/#{settings[:repo]}](#{url}) Stats " \
             "(Last #{settings[:days]} days)_*")

    if %w[all pr issue].any? { |m| mode.include?(m) }
      stats = get_pr_and_issue_stats(client, settings)
      %w[PR Issue].each do |type|
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
end # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

main if __FILE__ == $PROGRAM_NAME
