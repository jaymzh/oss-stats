#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'yaml'
require 'base64'
require 'uri'
require 'optparse'
require 'fileutils'
require 'mixlib/shellout'
require 'set'

require_relative 'lib/oss_stats/github_token'
require_relative 'lib/oss_stats/buildkite_token'
require_relative 'lib/oss_stats/log'
require_relative 'lib/oss_stats/buildkite_client'

def github_api_get(path, token)
  uri = URI("https://api.github.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Accept'] = 'application/vnd.github+json'
  req['User-Agent'] = 'private-pipeline-checker'

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(req)
  end
  unless res.is_a?(Net::HTTPSuccess)
    raise "GitHub API error: #{res.code} #{res.body}"
  end

  JSON.parse(res.body)
end

def get_expeditor_config(org, repo, token)
  path = "/repos/#{org}/#{repo}/contents/.expeditor/config.yml"
  res = github_api_get(path, token)
  Base64.decode64(res['content'])
rescue
  nil
end

def patch_yaml_public_flag!(text, pipeline_names)
  lines = text.lines
  current_pipeline = nil
  modified = false

  lines.each_with_index do |line, idx|
    match = line.match(/^\s*-\s+(\S+?)(:)?\s*$/)
    next unless match
    log.trace("Processing line #{line}")
    current_pipeline = Regexp.last_match(1)
    has_block = Regexp.last_match(2)
    indent = line[/^\s*/] + '  '

    log.trace("Line is for #{current_pipeline}")
    next unless pipeline_names.include?(current_pipeline)
    log.trace("... which is a pipeline from #{pipeline_names}")
    if has_block
      next if lines[idx + 1..idx + 5].any? { |l| l =~ /^\s*public:\s*true/ }
    else
      lines[idx] = "  #{line.strip}:\n"
    end
    lines.insert(idx + 1, indent + "  public: true\n")
    modified = true
  end

  modified ? lines.join : nil
end

def run_cmd!(args, cwd: nil, echo: true, retries: 0)
  log.debug("Running: #{args.join(' ')}")
  cmd = Mixlib::ShellOut.new(args, cwd:)
  cmd.run_command
  cmd.error!
  puts cmd.stdout if echo
  cmd.stdout
rescue Mixlib::ShellOut::ShellCommandFailed
  if retries > 0
    log.warn("Retrying command: #{args.join(' ')}")
    retries -= 1
    sleep(5)
    retry
  end
  raise
end

def output(fh, msg)
  if fh
    fh.write("#{msg}\n")
  else
    log.info(msg)
  end
end

def process_expeditor_pipelines(repo_info, options, github_token, log)
  # Assuming repo_info is already fetched and confirmed public
  repo = repo_info['name'] # Get repo name from repo_info
  content = get_expeditor_config(options[:github_org], repo, github_token)
  unless content
    log.debug("No expeditor config for #{repo}")
    return [] # Return empty list, no private pipelines found
  end

  begin
    config = YAML.safe_load(content)
  rescue Psych::SyntaxError => e
    log.warn("Skipping #{repo} due to YAML error: #{e}")
    return [] # Return empty list
  end

  pipelines = config['pipelines'] || []
  repo_missing_public_gh = []

  pipeline_names = pipelines.map do |pl|
    pl.is_a?(String) ? pl : pl.keys
  end.flatten

  pipelines.each do |pipeline_block|
    pipeline_block = { pipeline_block => {} } if pipeline_block.is_a?(String)

    pipeline_block.each do |pipeline_name, pipeline_details|
      if options[:verify_only] && !pipeline_name.start_with?('verify')
        log.debug("Skipping non-verify pipeline #{pipeline_name}")
        next
      end

      if pipeline_name.end_with?('_private')
        pubname = pipeline_name.gsub('_private', '')
        if pipeline_names.include?(pubname)
          log.debug("Skipping #{pipeline_name}, #{pubname} exists")
          skipped_by_pattern[pipeline_name] += 1
          next
        end
        log.warn("There is a #{pipeline_name} pipeline but no #{pubname}")
      end

      skip_matched = options[:skip_patterns].find do |pat|
        pipeline_name.include?(pat)
      end

      if skip_matched
        skipped_by_pattern[skip_matched] += 1
        next
      end

      env = pipeline_details['env'] || []
      if env.any? { |i| i['ADHOC'] }
        log.warn(
          "#{pipeline_name} is marked as adhoc but isn't named as such",
        )
        skipped_by_pattern['adhoc'] += 1
        next
      end

      total_pipeline_count += 1
      if !pipeline_details.is_a?(Hash) || pipeline_details['public'] != true
        repo_missing_public_gh << pipeline_name
        private_pipeline_count += 1
      end
    end
  end

  # PR creation logic (specific to Chef Expeditor) - remains within this method
  if !repo_missing_public_gh.empty? && options[:make_prs_for].any? && options[:source_dir]
    pipelines_to_fix = repo_missing_public_gh & options[:make_prs_for]
    unless pipelines_to_fix.empty?
      patched = patch_yaml_public_flag!(content, pipelines_to_fix)
      if patched
        repo_path = File.join(options[:source_dir], repo)
        unless Dir.exist?(repo_path)
          run_cmd!(
            ['sj', 'sclone', "#{options[:github_org]}/#{repo}"],
            cwd: options[:source_dir],
          )
        end

        run_cmd!(%w{sj feature expeditor-public}, cwd: repo_path, retries: 2)
        expeditor_path = File.join(repo_path, '.expeditor', 'config.yml')
        FileUtils.mkdir_p(File.dirname(expeditor_path))
        File.write(expeditor_path, patched)

        run_cmd!(['git', 'add', expeditor_path], cwd: repo_path)
        run_cmd!(
          [
            'git',
            'commit',
            '-sm',
            "make pipelines public: #{pipelines_to_fix.join(', ')}",
          ],
          cwd: repo_path,
        )

        unless options[:assume_yes]
          puts "\nDiff for #{repo}:"
          run_cmd!(
            ['git', '--no-pager', 'diff', 'HEAD~1'], cwd: repo_path
          )
          print 'Create PR? [y/N] '
          confirm = $stdin.gets.strip.downcase
          # next unless confirm == 'y' # This 'next' would skip the return
          return repo_missing_public_gh unless confirm == 'y'
        end

        run_cmd!(%w{sj spush}, cwd: repo_path, retries: 2)
        run_cmd!(%w{sj spr}, cwd: repo_path, retries: 2)
      end
    end
  end
  repo_missing_public_gh # This is the list of private pipeline names
end

def process_buildkite_pipelines( # rubocop:disable Metrics/ParameterLists
  repo_info,
  options,
  github_token,
  buildkite_token, # Token for primary org, used for new clients too
  log,
  buildkite_clients_by_org, # Hash to store/retrieve clients
  buildkite_slug_visibility_lookup, # Pre-fetched visibilities for primary org
  # Original map of repo_url to pipeline list for primary org:
  primary_org_pipelines_map_data # Renamed from buildkite_pipelines_data
)
  repo_url = repo_info['html_url']
  # repo name for logging, consistent with process_expeditor_pipelines
  repo_name = repo_info['name']
  # This list will store strings describing private pipelines for this repo
  local_repo_missing_public_bk = []
  # This set tracks unique "#{org}/#{slug}" for this repo to avoid duplicates
  local_reported_slugs = Set.new

  # Section 1: Process pipelines from direct association (primary org)
  pipelines_for_this_repo_direct = primary_org_pipelines_map_data.fetch(repo_url, [])
  log.debug("Processing direct BK pipelines for #{repo_name} (URL: #{repo_url})")
  if pipelines_for_this_repo_direct.any? # Guard clause might be slightly cleaner
    # This log was a bit verbose, simplified below if block is entered
    # log.debug("Found #{pipelines_for_this_repo_direct.count} BK pipeline(s) for " +
    #           "#{repo_url} via direct association (org: #{options[:buildkite_org]}).")

    pipelines_for_this_repo_direct.each do |p_info|
      slug = p_info[:slug]
      visibility = p_info[:visibility] # Already known from initial scan
      log.debug("Direct pipeline: #{options[:buildkite_org]}/#{slug}, visibility: #{visibility}")

      skip = options[:skip_patterns].find { |pat| slug.include?(pat) }
      if skip
        log.debug("Skipping #{slug} due to pattern: #{skip}")
        skipped_by_pattern[slug] += 1 # Modifies global var
        next
      end

      total_pipeline_count += 1 # Modifies global var
      next if visibility.casecmp('public').zero?

      report_key = "#{options[:buildkite_org]}/#{slug}"
      if local_reported_slugs.add?(report_key)
        log.warn("Pipeline #{report_key} is #{visibility} (direct)")
        local_repo_missing_public_bk << "#{slug} (#{visibility}) (Org: #{options[:buildkite_org]})"
        private_pipeline_count += 1 # Modifies global var
      end
    end
  else
    log.debug("No BK pipelines for repo #{repo_name} in primary org data (direct).")
  end

  # Section 2: PR Analysis Logic
  log.info("Starting BK PR analysis for #{repo_name} (URL: #{repo_url})")
  recent_prs = []

    primary_org_pipelines_for_repo.each do |pipeline_info|
      pipeline_slug = pipeline_info[:slug]
      visibility = pipeline_info[:visibility] # Already known from all_pipelines

      log.debug("Processing directly associated pipeline #{options[:buildkite_org]}/#{pipeline_slug} " +
                "for #{repo_url}")

      skip_matched = options[:skip_patterns].find do |pat|
        pipeline_slug.include?(pat)
      end

      if skip_matched
        log.debug("Skipping pipeline #{pipeline_slug} due to pattern: " +
                  skip_matched.to_s)
        skipped_by_pattern[pipeline_slug] += 1 # Use slug for pattern key
        next
      end

      total_pipeline_count += 1 # Count towards total if not skipped
      unless visibility.casecmp('public').zero?
        report_key = "#{options[:buildkite_org]}/#{pipeline_slug}"
        if reported_slugs_for_repo.add?(report_key)
          log.warn("Pipeline #{report_key} is #{visibility} (direct)")
          repo_missing_public_bk << "#{pipeline_slug} (#{visibility}) (Org: #{options[:buildkite_org]})"
          private_pipeline_count += 1
        else
          log.debug("Pipeline #{report_key} (direct) already noted as " +
                    "private for #{repo_url}")
        end
      else
        log.debug("Pipeline #{options[:buildkite_org]}/#{pipeline_slug} (direct) is public.")
      end
    end
  else
    log.debug("No Buildkite pipelines found for repo #{repo_url} in " +
              'primary org data (direct association).')
  end

  # --- PR Analysis Logic ---
  log.info("Starting Buildkite PR analysis for #{repo_url}")
  begin
    prs_path = "/repos/#{options[:github_org]}/#{repo}/pulls"
    pr_query_params = {
      state: 'all', sort: 'updated', direction: 'desc', per_page: 3,
    }
    pr_uri = URI(prs_path)
    pr_uri.query = URI.encode_www_form(pr_query_params)
    recent_prs = github_api_get(pr_uri.request_uri, github_token)
  rescue StandardError => e
    log.error("Error fetching PRs for #{repo_url}: #{e.message}")
    recent_prs = []
  end

  recent_prs.each do |pr_data|
    pr_number = pr_data['number']
    commit_sha = pr_data.dig('head', 'sha')

    unless commit_sha
      log.warn("Could not find commit SHA for PR ##{pr_number} in #{repo_url}. Skipping.")
      next
    end
    log.info("Analyzing PR ##{pr_number} (SHA: #{commit_sha}) in #{repo_url}")

    statuses_path = "/repos/#{options[:github_org]}/#{repo}/commits/#{commit_sha}/statuses"
    statuses = []
    begin
      log.debug("Fetching statuses for commit #{commit_sha} (PR ##{pr_number})")
      statuses = github_api_get(statuses_path, github_token)
    rescue StandardError => e
      log.error("Error fetching statuses for commit #{commit_sha} (PR ##{pr_number}) " +
                "in #{repo_url}: #{e.message}")
      next
    end

    if statuses.empty?
      log.debug("No statuses found for commit #{commit_sha} (PR ##{pr_number}).")
      next
    end

    log.debug("Processing #{statuses.count} statuses for commit #{commit_sha} (PR ##{pr_number})")

    unique_org_slug_pairs_from_statuses = Set.new
    statuses.each do |status|
      target_url = status['target_url']
      next unless target_url.is_a?(String) && !target_url.empty?
      bk_url_match = target_url.match(%r{https://buildkite\.com/([^/]+)/([^/]+)})
      next unless bk_url_match && bk_url_match.captures.length == 2
      unique_org_slug_pairs_from_statuses.add([bk_url_match[1], bk_url_match[2]])
    end

    unique_org_slug_pairs_from_statuses.each do |current_pipeline_org, current_pipeline_slug|
      log.info("Processing status-discovered pipeline: org=#{current_pipeline_org}, " +
               "slug=#{current_pipeline_slug} (PR ##{pr_number}, SHA: #{commit_sha})")

      visibility = nil
      discovery_method = ""

      client_to_use = nil
      if current_pipeline_org == options[:buildkite_org]
        client_to_use = buildkite_clients_by_org[options[:buildkite_org]]
        details_from_lookup = buildkite_slug_visibility_lookup[current_pipeline_slug]
        if details_from_lookup
          visibility = details_from_lookup[:visibility]
          discovery_method = 'from initial scan'
          log.debug("Visibility for #{current_pipeline_org}/#{current_pipeline_slug} " +
                    "from initial scan: #{visibility}")
        else
          log.warn("Slug #{current_pipeline_slug} from primary org " +
                   "#{options[:buildkite_org]} not in initial scan. Querying directly.")
          discovery_method = 'queried directly'
        end
      else # Different Buildkite organization
        discovery_method = 'queried directly'
        log.info("Pipeline is from a different org: #{current_pipeline_org}. Ensuring client exists.")
        client_to_use = buildkite_clients_by_org.fetch(current_pipeline_org) do |org_to_fetch|
          log.info("Creating new Buildkite client for org: #{org_to_fetch}")
          # Ensure buildkite_token is available in this scope
          buildkite_clients_by_org[org_to_fetch] = OssStats::BuildkiteClient.new(buildkite_token, org_to_fetch)
        end
      end

      if visibility.nil? && client_to_use
        begin
          log.debug("Querying API for #{current_pipeline_org}/#{current_pipeline_slug}")
          pipeline_data = client_to_use.get_pipeline(current_pipeline_slug)
          visibility = pipeline_data&.dig('visibility')
          discovery_method = 'queried directly' if discovery_method.empty?
        rescue StandardError => e
          log.error("Error querying API for #{current_pipeline_org}/#{current_pipeline_slug}: #{e.message}")
          discovery_method = 'API error'
        end
      elsif visibility.nil? && client_to_use.nil? && current_pipeline_org == options[:buildkite_org]
        log.error("Failed to get client for primary org #{options[:buildkite_org]} to query #{current_pipeline_slug}")
        discovery_method = 'client error'
      end

      source_info = "(via PR ##{pr_number}"
      source_info += ", Org: #{current_pipeline_org}" if current_pipeline_org != options[:buildkite_org]
      source_info += ", #{discovery_method})"

      if visibility
        log.info("Determined visibility for #{current_pipeline_org}/#{current_pipeline_slug} " +
                 "#{source_info}: #{visibility}")
        unless visibility.casecmp('public').zero?
          report_key = "#{current_pipeline_org}/#{current_pipeline_slug}"
          if reported_slugs_for_repo.add?(report_key)
            entry_msg = "#{current_pipeline_slug} (#{visibility}) #{source_info}"
            log.warn("Private pipeline found via PR status: #{report_key} is #{visibility}")
            repo_missing_public_bk << entry_msg
            private_pipeline_count += 1
          else
            log.debug("Pipeline #{report_key} (via PR) already reported as private.")
          end
        end
      else
        log.warn("Could not determine visibility for pipeline " +
                 "#{current_pipeline_org}/#{current_pipeline_slug} #{source_info}.")
      end
    end
  end
  repo_missing_public_bk
end

# Command-line options
options = {
  assume_yes: false,
  log_level: :info,
  make_prs_for: [],
  pipeline_format: '%{github_org}-%{repo}-%{branch}-verify',
  provider: 'buildkite',
  repos: %w{},
  skip_patterns: %w{adhoc release},
  skip_repos: [],
  verify_only: true,
}

OptionParser.new do |opts|
  opts.banner = 'Usage: check_gh_pipelines.rb [options]'

  opts.on(
    '--assume-yes',
    'If set, do not prompt before making PRs.',
  ) { options[:assume_yes] = true }

  opts.on(
    '--github-token TOKEN',
    'GitHub personal access token (or use GITHUB_TOKEN env var)',
  ) { |val| options[:github_token] = val }

  opts.on(
    '-l LEVEL',
    '--log-level LEVEL',
    'Set logging level to LEVEL. [default: info]',
  ) { |level| options[:log_level] = level.to_sym }

  opts.on(
    '--make-prs-for NAMES',
    Array,
    'Comma-separated list of pipeline names to make public if found private.',
  ) { |v| options[:make_prs_for] += v }

  opts.on(
    '--github-org ORG',
    'GitHub org name to look at all repos for. Required.',
  ) { |v| options[:github_org] = v }

  opts.on(
    '-o FILE',
    '--output FILE',
    'Write the output to FILE',
  ) { |v| options[:output] = v }

  opts.on(
    '--repos REPO',
    Array,
    'GitHub repositories name. Can specify comma-separated list and/or ' +
    ' use the option multiple times. Leave blank for all repos in the org.',
  ) { |v| options[:repos] += v }

  opts.on(
    '--skip PATTERN',
    Array,
    'Pipeline name substring to skip. Can specify a comma-separated list ' +
    ' and/or use the option multiple times. ' +
    "[default: #{options[:skip_patterns].join(',')}]",
  ) { |v| options[:skip_patterns] += v }

  opts.on(
    '--skip-repos REPOS',
    Array,
    'Comma-separated list of repos to skip even if they are public.',
  ) { |v| options[:skip_repos] += v }

  opts.on(
    '--source-dir DIR',
    'Directory to look for or clone the repo into.',
  ) { |v| options[:source_dir] = v }

  opts.on(
    '--[no-]verify-only',
    'By default we only look at verify pipelines as those are the only ' +
    'ones that run on PRs. Use --no-verify-only to change this',
  ) { |v| options[:verify_only] = v }

  opts.on(
    '--provider PROVIDER',
    %w{expeditor buildkite},
    'CI provider to use: buildkite or expeditor. ' +
    "Default: #{options[:provider]}",
  ) { |v| options[:provider] = v }

  opts.on(
    '--buildkite-token TOKEN',
    'Buildkite API token (or use BUILDKITE_TOKEN env var)',
  ) { |v| options[:buildkite_token] = v }

  opts.on(
    '--buildkite-org ORG',
    'Buildkite organization slug',
  ) { |v| options[:buildkite_org] = v }

  opts.on(
    '--pipeline-format FORMAT',
    'Expected pipeline name format string. ' +
    "Default: #{options[:pipeline_format]}",
  ) { |v| options[:pipeline_format] = v }
end.parse!

log.level = options[:log_level] if options[:log_level]
options[:skip_patterns].uniq!
options[:repos].uniq!
options[:make_prs_for].uniq!

if options[:output]
  fh = open(options[:output], 'w')
  log.info("Generating report and writing to #{options[:output]}")
end

github_token = get_github_token!(options)
buildkite_client = nil
if options[:provider] == 'buildkite'
  unless options[:buildkite_org]
    raise ArgumentError, 'buildkite org required for buildkite provider'
  end
  buildkite_token = get_buildkite_token!(options)
  buildkite_client = OssStats::BuildkiteClient.new(
    buildkite_token, options[:buildkite_org]
  )
  log.info('Fetching all Buildkite pipelines...')
  # buildkite_pipelines_data format: { "repo_url" => [{slug:, visibility:}, ...] }
  buildkite_pipelines_data = buildkite_client.all_pipelines
  bk_pipeline_count = buildkite_pipelines_data.values.flatten.count
  bk_repo_count = buildkite_pipelines_data.keys.count
  log.info("Found #{bk_pipeline_count} Buildkite pipelines across " +
           "#{bk_repo_count} repositories.")

  # Create a global lookup for slug -> {visibility:, repo_url:} for efficiency
  buildkite_slug_visibility_lookup = {}
  buildkite_pipelines_data.each do |repo_url, pipelines|
    pipelines.each do |p_info|
      # Keyed by slug only, assuming slugs are unique across one org's pipelines
      buildkite_slug_visibility_lookup[p_info[:slug]] = {
        visibility: p_info[:visibility],
        repo_url: repo_url
      }
    end
  end
  log.debug("Created Buildkite slug lookup table for primary org with " +
            "#{buildkite_slug_visibility_lookup.keys.size} unique slugs.")

  # Hash to store Buildkite clients, keyed by org slug
  buildkite_clients_by_org = {}
  buildkite_clients_by_org[options[:buildkite_org]] = buildkite_client
  log.info("Initialized Buildkite client for primary org: #{options[:buildkite_org]}")

elsif options[:provider] != 'expeditor'
  raise ArgumentError, "Unsupported provider: #{options[:provider]}"
end

total_pipeline_count = 0
private_pipeline_count = 0
repos_with_private = 0
skipped_by_pattern = Hash.new(0)

output(fh, "Pipeline Visibility Report #{Date.today}\n")
if options[:repos].empty?
  log.info("Fetching repos under '#{options[:github_org]}'...")
  page = 1
  loop do
    list = github_api_get(
      "/orgs/#{options[:github_org]}/repos?per_page=100&page=#{page}",
      github_token,
    )
    break if list.empty?

    priv = list.select { |r| r['private'] }.map { |r| r['name'] }
    unless priv.empty?
      log.debug("Found private repos: #{priv.join(', ')}")
    end

    options[:repos].concat(
      list.select { |r| !r['private'] }.map { |r| r['name'] },
    )
    page += 1
  end
  log.debug("Discovered these public repos: #{options[:repos].join(', ')}")
end

options[:repos].each do |repo|
  next if options[:skip_repos].include?(repo)
  private_pipelines_for_this_repo = []

  begin
    repo_info = github_api_get(
      "/repos/#{options[:github_org]}/#{repo}", github_token
    )
  rescue StandardError => e
    log.error("Error fetching repo info for #{options[:github_org]}/#{repo}: " +
              e.message)
    log.error("Skipping this repository.")
    next # Skip to the next repo
  end

  if repo_info['private']
    log.debug("Skipping private repo: #{repo}")
    next
  end

  print('.') if fh

  if options[:provider] == 'expeditor'
    # repo_info is passed, options are global, github_token is global, log is global
    # The method process_expeditor_pipelines will modify global counters like
    # total_pipeline_count, private_pipeline_count, skipped_by_pattern.
    # It returns a list of private pipeline names for this repo.
    private_pipelines_for_this_repo = process_expeditor_pipelines(
      repo_info, options, github_token, log
    )
  elsif options[:provider] == 'buildkite'
    # Ensure all necessary Buildkite-specific variables are passed.
    # These were initialized when options[:provider] == 'buildkite' was first checked.
    # - buildkite_token (top-level)
    # - buildkite_clients_by_org (top-level)
    # - buildkite_slug_visibility_lookup (top-level)
    # - buildkite_pipelines_data (top-level, used as primary_org_pipelines_map_data)
    private_pipelines_for_this_repo = process_buildkite_pipelines(
      repo_info,
      options,
      github_token,
      buildkite_token,
      log,
      buildkite_clients_by_org,
      buildkite_slug_visibility_lookup,
      buildkite_pipelines_data # Pass the original data structure
    )
  end
end

# --- Unified Output Section ---
unless private_pipelines_for_this_repo.empty?
  # Construct repo identifier using html_url from repo_info if available
  repo_html_url = repo_info['html_url']
  repo_identifier = if repo_html_url
                      "#{options[:github_org]}/#{repo} (#{repo_html_url})"
                    else
                      # Fallback if html_url is not present for some reason
                      "#{options[:github_org]}/#{repo}"
                    end
  output(fh, "* #{repo_identifier}")
  private_pipelines_for_this_repo.sort.each do |pipeline_entry|
    output(fh, "    * #{pipeline_entry}")
  end
  repos_with_private += 1
end

if total_pipeline_count > 0
  percentage_private = (
    (private_pipeline_count.to_f / total_pipeline_count.to_f) * 100
  ).round(2)
  output(fh, "\nTotal percentage of private pipelines: #{percentage_private}%")
  output(
    fh,
    "  --> #{private_pipeline_count} out of #{total_pipeline_count} " +
    "across #{repos_with_private} repos",
  )

  if skipped_by_pattern.any?
    output(fh, '  --> Skipped pipelines:')
    skipped_by_pattern.each do |pattern, count|
      output(fh, "    - #{pattern}: #{count}")
    end
  end
else
  output(fh, 'No pipelines found (excluding skipped patterns).')
end

puts if fh
fh.close if options[:output]
