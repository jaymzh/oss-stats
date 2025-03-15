#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'set'

# Load configuration
begin
  require_relative '../config/initializers/config'
rescue LoadError => e
  puts "ERROR: Configuration system not loaded: #{e.message}"
  puts 'The config gem may not be installed.'
  puts "Run 'bundle install' to install dependencies."
  puts 'Using hardcoded defaults.'
rescue StandardError => e
  puts "ERROR: Configuration failed to load: #{e.message}"
  puts 'Check your configuration files for syntax errors or'
  puts 'missing required fields.'
  puts 'Using hardcoded defaults.'
end

# Get GitHub token from environment or GitHub CLI config
def get_github_token
  # First check if token is provided via environment variable
  return ENV['GITHUB_TOKEN'] if ENV['GITHUB_TOKEN']

  # Then try to get from GitHub CLI config
  config_path = File.expand_path('~/.config/gh/hosts.yml')
  if File.exist?(config_path)
    config = YAML.load_file(config_path)
    token = config.dig('github.com', 'oauth_token')
    return token if token
  end

  # Finally, try to use gh CLI directly to get token
  begin
    gh_token = `gh auth token 2>/dev/null`.strip
    return gh_token unless gh_token.empty?
  rescue StandardError => e
    if ENV['VERBOSE']
      puts "Warning: Failed to get token from gh CLI: #{e.message}"
    end
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
         !labels.include?('Status: Waiting on Contributor') &&
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
  start_time = Time.now
  # Default timeout: 3 minutes
  max_ci_processing_time = options[:ci_timeout] || 180

  if options[:verbose]
    puts "Starting CI processing for #{repo}" \
         "(timeout: #{max_ci_processing_time}s)"
  end

  options[:branches].each do |b|
    failed_tests[b] = {}
  end

  options[:branches].each do |branch|
    if options[:verbose]
      puts "Checking workflow runs for branch: #{branch}"
    end

    begin
      workflows_response = client.workflows(repo)
      if options[:verbose]
        puts "  Found #{workflows_response.workflows.count} workflows"
      end

      workflows_response.workflows.each do |workflow|
        # Check if we've exceeded our timeout
        if Time.now - start_time > max_ci_processing_time
          if options[:verbose]
            puts 'CI processing timeout reached' \
                 "(#{max_ci_processing_time}s). Returning partial results."
          end
          return failed_tests
        end

        if options[:verbose]
          puts "  Workflow: #{workflow.name} (ID: #{workflow.id})"
        end
        workflow_runs = []
        page = 1

        begin
          loop do
            if options[:verbose]
              puts "    Acquiring page #{page} of workflow runs"
            end
            runs = client.workflow_runs(repo, workflow.id, branch:,
                    status: 'completed', per_page: 100, page:)

            if options[:verbose]
              count = runs.workflow_runs.count
              puts "    Retrieved #{count} runs on page #{page}"
            end
            break if runs.workflow_runs.empty?

            workflow_runs.concat(runs.workflow_runs)

            # Check if we've reached the cutoff date
            # Get date of the last run for cutoff comparison
            is_empty = runs.workflow_runs.empty?
            last_run_date = if is_empty
                              nil
                            else
                              runs.workflow_runs.last.created_at.to_date
                            end
            if !runs.workflow_runs.empty? && last_run_date < cutoff_date
              if options[:verbose]
                date_str = cutoff_date.to_s
                puts "    Reached cutoff date (#{date_str})," \
                     'stopping pagination'
              end
              break
            end

            page += 1

            # Check timeout after each page
            next unless Time.now - start_time > max_ci_processing_time
            if options[:verbose]
              puts 'CI processing timeout reached' \
                   "(#{max_ci_processing_time}s). Returning partial results."
            end
            return failed_tests
          end
        rescue Octokit::NotFound => e
          if options[:verbose]
            puts "    Error: Workflow runs not found - #{e.message}"
          end
          next
        rescue StandardError => e
          if options[:verbose]
            puts "    Error retrieving workflow runs: #{e.message}"
          end
          next
        end

        if options[:verbose]
          puts "    Processing #{workflow_runs.count} workflow runs"
        end
        workflow_runs.sort_by!(&:created_at)
        last_failure_date = {}

        workflow_runs.each do |run|
          # Check timeout after each run
          if Time.now - start_time > max_ci_processing_time
            if options[:verbose]
              puts 'CI processing timeout reached' \
                   "(#{max_ci_processing_time}s). Returning partial results."
            end
            return failed_tests
          end

          if options[:verbose]
            puts "    Processing workflow run #{run.id} (#{run.created_at})"
          end
          run_date = run.created_at.to_date
          next if run_date < cutoff_date

          begin
            jobs_response = client.workflow_run_jobs(repo, run.id)
            jobs = jobs_response.jobs
            puts "      Found #{jobs.count} jobs" if options[:verbose]

            jobs.each do |job|
              if options[:verbose]
                puts "      Job: #{job.name} [#{job.conclusion}]"
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
            end
          rescue Octokit::NotFound => e
            if options[:verbose]
              puts "      Error: Jobs not found for run #{run.id}" \
                   "- #{e.message}"
            end
            next
          rescue StandardError => e
            if options[:verbose]
              puts "      Error getting jobs for run #{run.id}: #{e.message}"
            end
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
    rescue Octokit::NotFound => e
      puts "  Error: Workflows not found - #{e.message}" if options[:verbose]
      next
    rescue StandardError => e
      puts "  Error retrieving workflows: #{e.message}" if options[:verbose]
      next
    end
  end

  if options[:verbose]
    puts "CI processing completed in #{(Time.now - start_time).round(2)}s"
  end
  failed_tests
end

def print_pr_or_issue_stats(stats, item)
  item_plural = item + 's'
  puts "\n  #{item} Stats:"
  puts "    Opened #{item_plural}: #{stats[:opened]}"
  puts "    Closed #{item_plural}: #{stats[:closed]}"
  if stats[:oldest_open]
    puts "    Oldest Open #{item}: #{stats[:oldest_open]}" +
         " (#{stats[:oldest_open_days]} days open, last activity" +
         " #{stats[:oldest_open_last_activity]} days ago)"
  end
  puts "    Stale #{item} (>30 days without comment): " +
       stats[:stale_count].to_s
  avg_time = stats[:avg_time_to_close_hours]
  avg_time_str = if avg_time > 24
                   (avg_time / 24).round(2).to_s + ' days'
                 else
                   avg_time.round(2).to_s + ' hours'
                 end
  puts "    Avg Time to Close #{item_plural}: #{avg_time_str}"
end

# Define defaults from config or use hardcoded values
options = if defined?(Settings)
            default_mode = if Settings.default_mode.is_a?(Array)
                             Settings.default_mode
                           else
                             [Settings.default_mode]
                           end
            # Get CI timeout from config with fallback to default
            # Get timeout with fallback
            has_timeout = Settings.respond_to?(:ci_timeout)
            ci_timeout = has_timeout ? Settings.ci_timeout : 180
            {
              org: Settings.default_org,
              repo: Settings.default_repo,
              branches: Settings.default_branches,
              days: Settings.default_days,
              verbose: false,
              mode: default_mode,
              ci_timeout:, # From config or default: 3 minutes
            }
          else
            {
              org: 'chef',
              repo: 'chef',
              branches: ['main'],
              days: 30,
              verbose: false,
              mode: ['all'],
              ci_timeout: 180, # Default: 3 minutes
            }
          end

valid_modes = %w{ci pr issue all}
OptionParser.new do |opts|
  opts.banner = 'Usage: chef_ci_status.rb [options]'

  opts.on(
    '--config CONFIG_FILE',
    'Path to custom configuration file',
  ) do |v|
    if File.exist?(v)
      begin
        # Load and parse the YAML file
        custom_config = begin
          YAML.load_file(v)
                        rescue Psych::SyntaxError => e
                          raise "Invalid YAML syntax in #{v}: #{e.message}"
        end

        # Verify it's a hash/dictionary
        unless custom_config.is_a?(Hash)
          raise 'Configuration file must contain a YAML dictionary/hash, ' \
                "not a #{custom_config.class}"
        end

        # Basic validation of required configuration keys
        required_keys = %w{default_org default_repo default_branches
default_days}
        missing_keys = required_keys.select { |key| !custom_config.key?(key) }
        unless missing_keys.empty?
          puts 'Warning: Missing recommended keys in config file: ' \
               "#{missing_keys.join(', ')}"
        end

        # Process all standard configuration keys
        if custom_config['default_org']
          if custom_config['default_org'].is_a?(String)
            options[:org] = custom_config['default_org']
          else
            puts 'Warning: default_org must be a string, ' \
                 "got #{custom_config['default_org'].class}"
          end
        end

        if custom_config['default_repo']
          if custom_config['default_repo'].is_a?(String)
            options[:repo] = custom_config['default_repo']
          else
            puts 'Warning: default_repo must be a string, ' \
                 "got #{custom_config['default_repo'].class}"
          end
        end

        if custom_config['default_branches']
          if custom_config['default_branches'].is_a?(Array)
            options[:branches] = custom_config['default_branches']
          else
            puts 'Warning: default_branches must be an array, ' \
                 "got #{custom_config['default_branches'].class}"
          end
        end

        if custom_config['default_days']
          if custom_config['default_days'].is_a?(Numeric)
            options[:days] = custom_config['default_days']
          else
            puts 'Warning: default_days must be a number, ' \
                 "got #{custom_config['default_days'].class}"
          end
        end

        if custom_config['default_mode']
          mode = custom_config['default_mode']
          options[:mode] = mode.is_a?(Array) ? mode : [mode]
        end

        # Process CI timeout configuration
        if custom_config['ci_timeout']
          if custom_config['ci_timeout'].is_a?(Numeric)
            options[:ci_timeout] = custom_config['ci_timeout']
          else
            puts 'Warning: ci_timeout must be a number, ' \
                 "got #{custom_config['ci_timeout'].class}"
          end
        end

        # Validate organizations if present
        if custom_config['organizations']
          if !custom_config['organizations'].is_a?(Hash)
            puts 'Warning: organizations must be a hash/dictionary'
          elsif custom_config['default_org'] &&
                # Check if default_org exists in organizations
                !custom_config['organizations'].key?(
                  custom_config['default_org'],
                )
            # Check if specified default_org exists in organizations
            puts "Warning: default_org '#{custom_config['default_org']}'" \
                 ' not found in organizations section'
          end
        end

        puts "Loaded custom configuration from #{v}"
      rescue => e
        puts "ERROR: Failed to load custom configuration: #{e.message}"
        puts 'Using default settings instead.'
        puts 'For configuration examples, see the examples/ directory.'
        exit(1) if ENV['CHEF_OSS_STATS_STRICT_CONFIG'] == 'true'
      end
    else
      puts "ERROR: Config file '#{v}' not found."
      puts 'Please provide a valid path to a configuration file.'
      puts 'For configuration examples, see the examples/ directory.'
      exit(1) if ENV['CHEF_OSS_STATS_STRICT_CONFIG'] == 'true'
    end
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

  opts.on(
    '--ci-timeout SECONDS',
    Integer,
    "Timeout for CI processing in seconds (default: #{options[:ci_timeout]})",
  ) do |v|
    options[:ci_timeout] = v
  end

  opts.on(
    '--skip-ci',
    'Skip CI status processing (faster)',
  ) do
    # Remove 'ci' from any mode array
    options[:mode] = options[:mode].reject do |m|
      m == 'ci'
    end if options[:mode].is_a?(Array)
    # Also handle 'all' mode
    options[:mode] = %w{pr issue} if options[:mode].include?('all')
  end

  opts.on(
    '--dry-run',
    'Skip all GitHub API calls (for testing)',
  ) do
    options[:dry_run] = true
  end
end.parse!
options[:mode] = %w{ci pr issue} if options[:mode].include?('all')

if options[:verbose]
  puts "Options: #{options}"
end

# Skip actual GitHub API calls in dry-run mode
if options[:dry_run]
  puts "[DRY RUN] Would analyze [#{options[:org]}/#{options[:repo]}]" \
       " Stats (Last #{options[:days]} days)"
  exit 0
end

github_token = get_github_token
unless github_token
  raise <<~ERROR
  GitHub token not found. Please authenticate using one of these methods:

  1. Set GITHUB_TOKEN environment variable:
     GITHUB_TOKEN=your_token #{$PROGRAM_NAME} [options]
  #{'   '}
  2. Use GitHub CLI authentication:
     gh auth login
  #{'   '}
  3. Use --dry-run option to skip GitHub API calls (for testing)
  ERROR
end

client = Octokit::Client.new(access_token: github_token)

puts "[#{options[:org]}/#{options[:repo]}] Stats (Last #{options[:days]} days)"

if options[:mode].include?('pr') || options[:mode].include?('issue')
  stats = get_pr_and_issue_stats(client, options)

  %w{PR Issue}.each do |item|
    if options[:mode].include?(item.downcase)
      print_pr_or_issue_stats(stats[item.downcase.to_sym], item)
    end
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
