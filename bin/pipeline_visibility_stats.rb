#!/usr/bin/env ruby

require 'base64'
require 'fileutils'
require 'json'
require 'mixlib/shellout'
require 'net/http'
require 'optparse'
require 'set'
require 'uri'
require 'yaml'

require_relative '../lib/oss_stats/buildkite_client'
require_relative '../lib/oss_stats/buildkite_token'
require_relative '../lib/oss_stats/github_client'
require_relative '../lib/oss_stats/github_token'
require_relative '../lib/oss_stats/log'

def get_expeditor_config(org, repo, client)
  path = "/repos/#{org}/#{repo}/contents/.expeditor/config.yml"
  res = client.get(path)
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

def process_expeditor_pipelines(repo_info, options, gh_client, log)
  total_pipeline_count = 0
  private_pipeline_count = 0
  skipped_by_pattern = Hash.new(0)

  # Assuming repo_info is already fetched and confirmed public
  repo = repo_info['name'] # Get repo name from repo_info
  content = get_expeditor_config(options[:github_org], repo, gh_client)
  unless content
    log.debug("No expeditor config for #{repo}")
    return { pipelines: [], total_processed: 0, private_found: 0,
             skipped_counts: skipped_by_pattern }
  end

  begin
    config = YAML.safe_load(content)
  rescue Psych::SyntaxError => e
    log.warn("Skipping #{repo} due to YAML error: #{e}")
    return { pipelines: [], total_processed: 0, private_found: 0,
             skipped_counts: skipped_by_pattern }
  end

  pipelines = config['pipelines'] || []
  repo_missing_public = []

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
        skipped_by_pattern[pipeline_name] += 1
        next
      end

      env = pipeline_details['env'] || []
      if env.any? { |i| i['ADHOC'] }
        log.warn("#{pipeline_name} is marked as adhoc but not named so")
        skipped_by_pattern[pipeline_name] += 1
        next
      end

      total_pipeline_count += 1
      if !pipeline_details.is_a?(Hash) || pipeline_details['public'] != true
        repo_missing_public << pipeline_name
        private_pipeline_count += 1
      end
    end
  end

  # PR creation logic (specific to Chef Expeditor) - remains within this method
  if !repo_missing_public.empty? && options[:make_prs_for].any? &&
     options[:source_dir]
    pipelines_to_fix = repo_missing_public & options[:make_prs_for]
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
        commit_message = "make pipelines public: #{pipelines_to_fix.join(', ')}"
        run_cmd!(
          ['git', 'commit', '-sm', commit_message],
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
          return repo_missing_public unless confirm == 'y'
        end

        run_cmd!(%w{sj spush}, cwd: repo_path, retries: 2)
        run_cmd!(%w{sj spr}, cwd: repo_path, retries: 2)
      end
    end
  end

  {
    pipelines: repo_missing_public,
    total_processed: total_pipeline_count,
    private_found: private_pipeline_count,
    skipped_counts: skipped_by_pattern,
  }
end

def process_buildkite_pipelines(
  repo_info,
  options,
  gh_client,
  log,
  bk_client,
  buildkite_slug_visibility_lookup,
  primary_org_pipelines_map_data
)
  total_pipeline_count = 0
  private_pipeline_count = 0
  skipped_by_pattern = Hash.new(0)

  repo_url = repo_info['html_url']
  # repo name for logging, consistent with process_expeditor_pipelines
  repo_name = repo_info['name']

  if repo_name.nil? || repo_name.empty?
    log.error('Repository name is nil or empty for ' \
              "#{repo_info['html_url'] || 'unknown URL'}. " +
              'Skipping Buildkite processing for this repo.')
    return { pipelines: [], total_processed: 0, private_found: 0,
             skipped_counts: skipped_by_pattern }
  end

  repo_missing_public = []
  # This set tracks unique "#{org}/#{slug}" for this repo to avoid duplicates
  reported_slugs = Set.new
  seen_slugs = Set.new

  # First, check to see if any pipelines in BK report being assocaited
  # with this repo
  pipelines_for_this_repo_direct =
    primary_org_pipelines_map_data.fetch(repo_url, [])
  pipelines_for_this_repo_direct&.each do |p_info|
    slug = p_info[:slug]
    visibility = p_info[:visibility] # Already known from initial scan
    log.debug("Direct pipeline: #{options[:buildkite_org]}/#{slug}, " +
              "vis: #{visibility}")

    skip = options[:skip_patterns].find { |pat| slug.include?(pat) }
    if skip
      log.debug("Skipping #{slug} due to pattern: #{skip}")
      skipped_by_pattern[report_key] += 1
      next
    end

    report_key = "#{options[:buildkite_org]}/#{slug}"
    next unless seen_slugs.add?(report_key)

    total_pipeline_count += 1
    next if visibility.casecmp('public').zero?

    if reported_slugs.add?(report_key)
      log.debug("Pipeline #{report_key} is #{visibility} (direct)")
      repo_missing_public << slug
      private_pipeline_count += 1
    end
  end

  # However, more likely, we don't have access to see the pipeline or
  # even the BK org. So walk the most recent PRs
  log.debug("Starting BK PR analysis for #{repo_name} (URL: #{repo_url})")
  recent_prs = gh_client.recent_prs(options[:github_org], repo_name)
  recent_prs.reject! { |pr| pr['draft'] }
  recent_prs.each do |pr_data|
    pr_number = pr_data['number']

    log.debug("Analyzing PR ##{pr_number}")
    statuses = gh_client.pr_statuses(pr_data)

    next if statuses.empty?

    # walk statuses and pulls all relevant buildkite URLs and uniqueify them
    unique_org_slug_pairs_from_statuses = Set.new
    statuses.each do |status|
      target_url = status['target_url']
      next unless target_url.is_a?(String) && !target_url.empty?
      bk_url_match = target_url.match(
        %r{https://buildkite\.com/([^/]+)/([^/]+)},
      )
      next unless bk_url_match && bk_url_match.captures.length == 2
      unique_org_slug_pairs_from_statuses.add(
        [bk_url_match[1], bk_url_match[2]],
      )
    end

    # walk buildkit URLs, and if we haven't seen them already, check
    # if they're public
    unique_org_slug_pairs_from_statuses.each do |bk_org, bk_slug|
      report_key = "#{bk_org}/#{bk_slug}"
      log.debug("Processing #{report_key} from PR")

      skip = options[:skip_patterns].find { |pat| bk_slug.include?(pat) }
      if skip
        log.debug("Skipping #{bk_slug} due to pattern: #{skip}")
        skipped_by_pattern[report_key] += 1
        next
      end

      # check if we already reported in this.
      next unless seen_slugs.add?(report_key)
      total_pipeline_count += 1

      visibility = nil
      discovery_method = ''

      if bk_org == options[:buildkite_org]
        details_from_lookup = buildkite_slug_visibility_lookup[bk_slug]
        if details_from_lookup
          # It was in our initial scan of all pipelines, but was not
          # reported as being associated with this repo, which is odd
          # but not impossible (for pipelines that people kick off
          # from some other source
          log.warn(
            "A PR has a pipeline we already knew about, but didn't" +
            'report on, wat?',
          )
          visibility = details_from_lookup[:visibility]
          discovery_method = 'from initial scan'
        end
      end

      unless visibility
        pipeline_data = bk_client.get_pipeline(bk_org, bk_slug)
        discovery_method = 'queried directly'
        visibility = pipeline_data&.dig('visibility')
      end

      next if visibility&.downcase == 'public'

      source_info = "(via PR ##{pr_number}"
      source_info += ", Org: #{bk_org}" if bk_org != options[:buildkite_org]
      source_info += ", #{discovery_method})"

      if reported_slugs.add?(report_key)
        repo_missing_public << report_key
        log.debug("#{report_key} source info: #{source_info}")
        private_pipeline_count += 1
      else
        log.debug(
          "Pipeline #{report_key} (via PR) already reported as private.",
        )
      end
    end
  end

  {
    pipelines: repo_missing_public,
    total_processed: total_pipeline_count,
    private_found: private_pipeline_count,
    skipped_counts: skipped_by_pattern,
  }
end

def main(options)
  if options[:output]
    fh = open(options[:output], 'w')
    log.info("Generating report and writing to #{options[:output]}")
  end

  github_token = get_github_token!(options)
  gh_client = OssStats::GitHubClient.new(github_token)
  bk_client = nil
  if options[:provider] == 'buildkite'
    unless options[:buildkite_org]
      raise ArgumentError, 'buildkite org required for buildkite provider'
    end
    buildkite_token = get_buildkite_token!(options)
    bk_client = OssStats::BuildkiteClient.new(buildkite_token)
    log.debug('Fetching all Buildkite pipelines...')
    buildkite_pipelines_data = bk_client.pipelines_by_repo(
      options[:buildkite_org],
    )
    bk_pipeline_count = buildkite_pipelines_data.values.flatten.count
    bk_repo_count = buildkite_pipelines_data.keys.count
    log.debug(
      "Found #{bk_pipeline_count} Buildkite pipelines across " +
       "#{bk_repo_count} repositories.",
    )

    # Create a global lookup for slug -> {visibility:, repo_url:} for efficiency
    buildkite_slug_visibility_lookup = {}
    buildkite_pipelines_data.each do |repo_url, pipelines|
      pipelines.each do |p_info|
        # Keyed by slug only, slugs are unique across one org's pipelines
        buildkite_slug_visibility_lookup[p_info[:slug]] = {
          visibility: p_info[:visibility],
          repo_url:,
        }
      end
    end
  elsif options[:provider] != 'expeditor'
    raise ArgumentError, "Unsupported provider: #{options[:provider]}"
  end

  total_pipeline_count = 0
  private_pipeline_count = 0
  repos_with_private = 0
  skipped_by_pattern = Hash.new(0)

  name = options[:github_org].capitalize
  output(fh, "# #{name} Pipeline Visibility Report #{Date.today}\n")
  if options[:repos].empty?
    log.debug("Fetching repos under '#{options[:github_org]}'...")
    page = 1
    loop do
      list = gh_client.get(
        "/orgs/#{options[:github_org]}/repos?per_page=100&page=#{page}",
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

  options[:repos].sort.each do |repo|
    next if options[:skip_repos].include?(repo)

    begin
      repo_info = gh_client.get("/repos/#{options[:github_org]}/#{repo}")
    rescue StandardError => e
      log.error(
        "Error fetching repo info for #{options[:github_org]}/#{repo}: " +
        e.message,
      )
      log.error('Skipping this repository.')
      next
    end

    if repo_info['private']
      log.debug("Skipping private repo: #{repo}")
      next
    end

    print('.') if fh

    result = {}
    if options[:provider] == 'expeditor'
      result = process_expeditor_pipelines(
        repo_info, options, gh_client, log
      )
    elsif options[:provider] == 'buildkite'
      result = process_buildkite_pipelines(
        repo_info,
        options,
        gh_client,
        log,
        bk_client,
        buildkite_slug_visibility_lookup,
        buildkite_pipelines_data,
      )
    end

    # Accumulate results from the processed provider
    private_pipelines_for_this_repo = result.fetch(:pipelines, [])
    total_pipeline_count += result.fetch(:total_processed, 0)
    private_pipeline_count += result.fetch(:private_found, 0)
    result.fetch(:skipped_counts, {}).each do |pattern, count|
      skipped_by_pattern[pattern] += count
    end

    next if private_pipelines_for_this_repo.empty?
    # Construct repo identifier using html_url from repo_info if available
    # 'repo' is the loop variable for the current repository name.
    # 'repo_info' is the hash of details for that specific repository.
    name = "#{options[:github_org]}/#{repo}"
    repo_html_url = repo_info['html_url']
    if repo_html_url
      name = "[#{name}](#{repo_html_url})"
    end
    output(fh, "* #{name}")
    private_pipelines_for_this_repo.sort.each do |pipeline_entry|
      output(fh, "    * #{pipeline_entry}")
    end
    repos_with_private += 1
  end

  if total_pipeline_count > 0
    percentage_private = (
      (private_pipeline_count.to_f / total_pipeline_count.to_f) * 100
    ).round(2)
    output(
      fh, "\nTotal percentage of private pipelines: #{percentage_private}%"
    )
    summary_line = format(
      '  --> %<private>d out of %<total>d across %<repos>d repos',
      private: private_pipeline_count,
      total: total_pipeline_count,
      repos: repos_with_private,
    )
    output(fh, summary_line)

    if skipped_by_pattern.any?
      output(fh, '  --> Skipped pipelines:')
      skipped_by_pattern.each_key do |pipeline|
        output(fh, "    - #{pipeline}")
      end
      output(fh, '  -> The following skip patterns were specified:')
      options[:skip_patterns].each do |pat|
        output(fh, "    - #{pat}")
      end
    end
  else
    output(fh, 'No pipelines found (excluding skipped patterns).')
  end

  puts if fh
  fh.close if options[:output]
end

# Command-line options
options = {
  assume_yes: false,
  log_level: :info,
  make_prs_for: [],
  pipeline_format: '%{github_org}-%{repo}-%{branch}-verify',
  provider: 'buildkite',
  repos: %w{},
  skip_patterns: %w{},
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
    'GitHub repositories name. Can specify comma-separated list and/or use ' +
    'the option multiple times. Leave blank for all repos in the org.',
  ) { |v| options[:repos] += v }

  opts.on(
    '--skip PATTERN',
    Array,
    'Pipeline name substring to skip. Can specify a comma-separated list ' +
    'and/or use the option multiple times. ' +
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
    'By default we only look at verify pipelines as those are the only ones ' +
    'that run on PRs. Use --no-verify-only to change this.',
  ) { |v| options[:verify_only] = v }

  opts.on(
    '--provider PROVIDER',
    %w{expeditor buildkite},
    'CI provider to use: buildkite or expeditor. Default: ' +
    options[:provider].to_s, # Ensure string for concatenation
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
    'Expected pipeline name format string. Default: ' +
    options[:pipeline_format].to_s, # Ensure string for concatenation
  ) { |v| options[:pipeline_format] = v }
end.parse!

log.level = options[:log_level] if options[:log_level]
options[:skip_patterns].uniq!
options[:repos].uniq!
options[:make_prs_for].uniq!

raise ArgumentError, 'GitHub org is required' unless options[:github_org]

main(options) if __FILE__ == $PROGRAM_NAME
