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
    log.debug("Sleeping for #{sleep_time.round(2)}s to honor rate-limit (max #{limit_gh_ops_per_minute} ops/min)")
    sleep(sleep_time)
  end
end

def get_pr_and_issue_stats(client, options)
  repo_name = "#{options[:org]}/#{options[:repo]}"
  cutoff_date = Date.today - options[:days]
  pr_stats = { open: 0, closed: 0, total_close_time: 0.0, oldest_open: nil, oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0, opened_this_period: 0 }
  issue_stats = { open: 0, closed: 0, total_close_time: 0.0, oldest_open: nil, oldest_open_days: 0, oldest_open_last_activity: 0, stale_count: 0, opened_this_period: 0 }
  prs = { open: [], closed: [] }
  issues = { open: [], closed: [] }
  stale_cutoff = Date.today - 30
  page = 1

  loop do
    rate_limited_sleep
    items = client.issues(repo_name, state: 'all', per_page: 100, page: page)
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
      stats = is_pr ? pr_stats : issue_stats
      list = is_pr ? prs : issues
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
          list[:open] << item
          all_items_before_cutoff = false
        end
      end
      next unless closed_date && closed_date >= cutoff_date
      next unless !is_pr || item.pull_request.merged_at
      list[:closed] << item
      stats[:closed] += 1
      stats[:total_close_time] += (item.closed_at - item.created_at) / 3600.0
      all_items_before_cutoff = false
    end
    page += 1
    break if all_items_before_cutoff
  end
  pr_stats[:avg_time_to_close_hours] = pr_stats[:closed].zero? ? 0 : pr_stats[:total_close_time] / pr_stats[:closed]
  issue_stats[:avg_time_to_close_hours] = issue_stats[:closed].zero? ? 0 : issue_stats[:total_close_time] / issue_stats[:closed]
  { pr: pr_stats, issue: issue_stats, pr_list: prs, issue_list: issues }
end

def get_failed_tests_from_ci(client, org_name, repo_name_short, branches_to_check, days_back, current_ci_timeout)
  full_repo_name = "#{org_name}/#{repo_name_short}"
  cutoff_date = Date.today - days_back
  today = Date.today
  failed_tests = {}
  processed_branches = branches_to_check.is_a?(String) ? branches_to_check.split(',').map(&:strip) : Array(branches_to_check).map(&:strip)
  processed_branches.each { |b| failed_tests[b] = {} }

  processed_branches.each do |branch_name|
    log.debug("Checking workflow runs for #{full_repo_name}, branch: #{branch_name}")
    begin
      rate_limited_sleep
      workflows_response = client.workflows(full_repo_name)
      workflows = workflows_response.workflows
      workflows.each do |workflow|
        log.debug("Workflow: #{workflow.name} (ID: #{workflow.id}) for #{full_repo_name}/#{branch_name}")
        workflow_runs = []
        page = 1
        loop do
          log.debug("  Acquiring page #{page} for workflow runs (#{full_repo_name}/#{branch_name})")
          rate_limited_sleep
          runs_page = client.workflow_runs(full_repo_name, workflow.id, branch: branch_name, status: 'completed', per_page: 30, page: page)
          break if runs_page.workflow_runs.empty?
          workflow_runs.concat(runs_page.workflow_runs)
          break if workflow_runs.last.created_at.to_date < cutoff_date || page > 10
          page += 1
        end
        workflow_runs.sort_by!(&:created_at).reverse!
        last_failure_date_for_job = {}
        workflow_runs.each do |run|
          run_date = run.created_at.to_date
          break if run_date < cutoff_date
          log.debug("  Looking at workflow run #{run.id} (##{run.run_number}) from #{run_date} for #{full_repo_name}/#{branch_name}")
          begin
            Timeout.timeout(current_ci_timeout || 300) do
              rate_limited_sleep
              jobs_response = client.workflow_run_jobs(full_repo_name, run.id, per_page: 100)
              jobs = jobs_response.jobs
              jobs.each do |job|
                log.debug("    Looking at job '#{job.name}' (ID: #{job.id}) - Conclusion: #{job.conclusion}")
                job_name_key = "#{workflow.name} / #{job.name}"
                if job.conclusion == 'failure'
                  failed_tests[branch_name][job_name_key] ||= Set.new
                  failed_tests[branch_name][job_name_key] << run_date
                  last_failure_date_for_job[job_name_key] = run_date
                elsif job.conclusion == 'success'
                  last_failure_date_for_job.delete(job_name_key) if last_failure_date_for_job[job_name_key] && last_failure_date_for_job[job_name_key] <= run_date
                end
              end
            end
          rescue Octokit::Error => oe
            log.error("Octokit error getting jobs for run #{run.id} (#{full_repo_name}/#{branch_name}): #{oe.message}")
          rescue Timeout::Error
            log.warn("Timeout fetching jobs for workflow run #{run.id} (#{full_repo_name}/#{branch_name}) after #{current_ci_timeout} seconds.")
          rescue StandardError => e
            log.error("Error processing jobs for run #{run.id} (#{full_repo_name}/#{branch_name}): #{e.class} - #{e.message}")
            log.debug e.backtrace.join("\n")
          end
        end
        last_failure_date_for_job.each do |job_key, last_fail_date|
          (last_fail_date + 1..today).each { |date| (failed_tests[branch_name][job_key] ||= Set.new) << date }
        end
      end
    rescue Octokit::NotFound => e
      log.warn "Workflow API returned 404 for #{full_repo_name} branch #{branch_name}: #{e.message}."
    rescue Octokit::Error, StandardError => e
      log.error "Error processing branch #{branch_name} for repo #{full_repo_name}: #{e.message}"
      log.debug e.backtrace.join("\n")
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
  if include_list && list[:closed]
    list[:closed].each { |item| log.info("        * [#{item.title} (##{item.number})](#{item.html_url}) - @#{item.user.login}") }
  end
  log.info("     * Open #{type_plural}: #{stats[:open]} (#{stats[:opened_this_period]} opened this period)")
  if include_list && list[:open]
    list[:open].each { |item| log.info("        * [#{item.title} (##{item.number})](#{item.html_url}) - @#{item.user.login}") }
  end
  if stats[:oldest_open]
    log.info("    * Oldest Open #{type}: #{stats[:oldest_open]} (#{stats[:oldest_open_days]} days open, last activity #{stats[:oldest_open_last_activity]} days ago)")
  end
  log.info("    * Stale #{type} (>30 days without comment): #{stats[:stale_count]}")
  avg_time = stats[:avg_time_to_close_hours]
  avg_time_str = avg_time > 24 ? "#{(avg_time / 24).round(2)} days" : "#{avg_time.round(2)} hours"
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
      jobs.sort.each { |job, dates| log.info("        * #{job}: #{dates.size} days") }
    end
  end
end

def parse_options # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  cli_options_hash = {}
  config_file_from_cli = nil

  # First OptionParser pass (for --config only)
  OptionParser.new do |opts|
    opts.on('--config FILE_PATH', String) do |f|
      config_file_from_cli = f
      cli_options_hash[:config_file_path] = f # Store it in the hash too
    end
  end.parse!(ARGV.dup, into: {}) # Parse copy of ARGV

  # Determine config file and load
  config_to_load = config_file_from_cli || OssStats::CiStatsConfig.config_file_to_load
  if config_to_load && File.exist?(config_to_load)
    OssStats::CiStatsConfig.from_file(config_to_load)
    OssStats::CiStatsConfig.config_file_loaded config_to_load
    log.info "Loaded configuration from: #{config_to_load}"
  elsif config_file_from_cli
    log.warn "Specified configuration file #{config_file_from_cli} not found. Using defaults and other CLI options."
  else
    log.info "No configuration file found or specified. Using defaults and CLI options."
  end

  # Second OptionParser pass (for all other options)
  valid_modes = %w{ci pr issue all}
  OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
    opts.on('--org ORG_NAME', String, "GitHub organization name") { |v| cli_options_hash[:org_from_cli] = v }
    opts.on('--repo REPO_NAME', String, "GitHub repository name") { |v| cli_options_hash[:repo_from_cli] = v }
    opts.on('--branches BRANCHES', Array, "Comma-separated list of branches") { |v| cli_options_hash[:default_branches] = v }
    opts.on('-d DAYS', '--days DAYS', Integer, "Number of days to analyze") { |v| cli_options_hash[:default_days] = v }
    opts.on('--config FILE_PATH', String, 'Path to a custom Ruby configuration file (already processed)') # Help only
    opts.on('--ci-timeout TIMEOUT', Integer, "Timeout for CI processing in seconds") { |v| cli_options_hash[:ci_timeout] = v }
    opts.on('--github-token TOKEN', 'GitHub personal access token') { |v| cli_options_hash[:github_access_token] = v }
    opts.on('--github-api-endpoint ENDPOINT', String, 'GitHub API endpoint') { |v| cli_options_hash[:github_api_endpoint] = v }
    opts.on('--limit-gh-ops-per-minute RATE', Float, 'Rate limit GitHub API ops') { |v| cli_options_hash[:limit_gh_ops_per_minute] = v }
    opts.on('-l LEVEL', '--log-level LEVEL', %i[debug info warn error fatal], "Logging level") { |v| cli_options_hash[:log_level] = v }
    opts.on('--mode MODE', Array, "Modes: #{valid_modes.join(', ')}") do |v|
      invalid_modes = v.map(&:downcase) - valid_modes
      raise OptionParser::InvalidArgument, "Invalid mode(s): #{invalid_modes.join(', ')}" unless invalid_modes.empty?
      cli_options_hash[:mode_from_cli] = v.map(&:downcase)
    end
    opts.on('--include-list', 'Include detailed lists of PRs/Issues') { cli_options_hash[:include_list] = true }
  end.parse! # This modifies ARGV

  # Prepare options for merging into OssStats::CiStatsConfig
  mergeable_cli_options = cli_options_hash.dup
  # These keys are handled differently or not merged directly into OssStats::CiStatsConfig globals
  [:org_from_cli, :repo_from_cli, :config_file_path, :mode_from_cli].each { |k| mergeable_cli_options.delete(k) }

  # Merge general CLI options into OssStats::CiStatsConfig
  # compact removes nil values for options not provided by CLI
  OssStats::CiStatsConfig.merge!(mergeable_cli_options.compact)

  # Finalize mode based on CLI or default from config (which itself defaults to ['all'])
  final_mode_list = cli_options_hash.key?(:mode_from_cli) ? cli_options_hash[:mode_from_cli] : OssStats::CiStatsConfig.default(:mode, ['all'])
  cli_options_hash[:mode_processed] = final_mode_list.include?('all') ? %w{ci pr issue} : final_mode_list

  cli_options_hash # Return the full hash of CLI inputs
end

def main # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  cli_options = parse_options

  log.level = OssStats::CiStatsConfig.log_level if OssStats::CiStatsConfig.log_level
  log.debug("Loaded final configuration: #{OssStats::CiStatsConfig.to_hash}")
  log.debug("CLI options from parser (includes processed mode): #{cli_options}")

  # Corrected GitHub Token Logic:
  # Call get_github_token! and store its return value.
  # get_github_token! checks OssStats::CiStatsConfig for a pre-set token first
  # (e.g., from CLI --github-token merged into config, or from config file value).
  # It will exit if no token can be found from any source.
  token = get_github_token!(OssStats::CiStatsConfig)
  OssStats::CiStatsConfig.github_access_token = token # Assign the found token back to the config object

  # Initialize Octokit::Client using the token now stored in config
  client = Octokit::Client.new(
    access_token: OssStats::CiStatsConfig.github_access_token,
    api_endpoint: OssStats::CiStatsConfig.github_api_endpoint
  )

  cli_org_value = cli_options[:org_from_cli]
  cli_repo_value = cli_options[:repo_from_cli]

  if cli_org_value && cli_repo_value
    log.info "Processing specific repository from CLI: #{cli_org_value}/#{cli_repo_value}"
    OssStats::CiStatsConfig.organizations = {
      cli_org_value => {
        'repositories' => {
          cli_repo_value => {} # Specific settings will be layered by get_effective_settings
        }
      }
    }
    OssStats::CiStatsConfig.default_org = cli_org_value
    OssStats::CiStatsConfig.default_repo = cli_repo_value
  elsif cli_org_value || cli_repo_value
    log.fatal "Error: Both --org and --repo must be specified if either is used. Exiting."
    exit 1
  end

  get_effective_settings = lambda do |target_org, target_repo, org_file_conf = {}, repo_file_conf = {}|
    settings = {}
    settings[:days]         = repo_file_conf['default_days'] || org_file_conf['default_days'] || OssStats::CiStatsConfig.default_days
    settings[:branches]     = repo_file_conf['default_branches'] || org_file_conf['default_branches'] || OssStats::CiStatsConfig.default_branches
    settings[:ci_timeout]   = repo_file_conf['ci_timeout'] || org_file_conf['ci_timeout'] || OssStats::CiStatsConfig.ci_timeout
    if repo_file_conf.key?('include_list')
      settings[:include_list] = repo_file_conf['include_list']
    elsif org_file_conf.key?('include_list')
      settings[:include_list] = org_file_conf['include_list']
    else
      settings[:include_list] = OssStats::CiStatsConfig.include_list
    end
    settings[:branches] = Array(settings[:branches].is_a?(String) ? settings[:branches].split(',').map(&:strip) : settings[:branches])
    settings.merge(org: target_org, repo: target_repo)
  end

  current_mode = cli_options[:mode_processed] # Corrected key
  repos_to_process = []

  if OssStats::CiStatsConfig.organizations.nil? || OssStats::CiStatsConfig.organizations.empty?
    log.warn "No organizations/repositories configured or specified to process. Exiting."
    exit 0
  else
    OssStats::CiStatsConfig.organizations.each do |org_name, org_config_from_file|
      (org_config_from_file['repositories'] || {}).each do |repo_name, repo_config_from_file_val|
        repos_to_process << get_effective_settings.call(org_name, repo_name, org_config_from_file, repo_config_from_file_val)
      end
    end
  end

  if repos_to_process.empty?
    log.warn "No repositories found to process after evaluating configuration. Exiting."
    exit 0
  end

  repos_to_process.each do |settings|
    log.info "\n--- Processing #{settings[:org]}/#{settings[:repo]} ---"
    log.info "*_[#{settings[:org]}/#{settings[:repo]}] Stats (Last #{settings[:days]} days)_*"
    if %w[pr issue].any? { |m| current_mode.include?(m) }
      stats = get_pr_and_issue_stats(client, { org: settings[:org], repo: settings[:repo], days: settings[:days] })
      %w[PR Issue].each do |type|
        print_pr_or_issue_stats(stats, type, settings[:include_list]) if current_mode.include?(type.downcase)
      end
    end
    if current_mode.include?('ci')
      test_failures = get_failed_tests_from_ci(client, settings[:org], settings[:repo], settings[:branches], settings[:days], settings[:ci_timeout])
      print_ci_status(test_failures || {}, {})
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
