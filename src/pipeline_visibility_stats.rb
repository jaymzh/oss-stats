#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'yaml'
require 'base64'
require 'uri'
require 'optparse'
require 'fileutils'
require 'mixlib/shellout'

require_relative 'lib/oss_stats/github_token'
require_relative 'lib/oss_stats/log'

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

# Command-line options
options = {
  skip_patterns: %w{adhoc release},
  repos: %w{},
  org: 'chef',
  log_level: :info,
  make_prs_for: [],
  source_dir: nil,
  assume_yes: false,
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
    '--org ORG',
    "GitHub org name. [default: #{options[:org]}]",
  ) { |v| options[:org] = v }

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

total_pipeline_count = 0
private_pipeline_count = 0
repos_with_private = 0
skipped_by_pattern = Hash.new(0)

output(fh, "Pipeline Visibility Report #{Date.today}\n")
if options[:repos].empty?
  log.info("Fetching repos under '#{options[:org]}'...")
  page = 1
  loop do
    list = github_api_get(
      "/orgs/#{options[:org]}/repos?per_page=100&page=#{page}",
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
  repo_info = github_api_get("/repos/#{options[:org]}/#{repo}", github_token)
  if repo_info['private']
    log.debug("Skipping private repo: #{repo}")
    next
  end

  print('.') if fh

  content = get_expeditor_config(options[:org], repo, github_token)
  unless content
    log.debug("No expeditor config for #{repo}")
    next
  end

  begin
    config = YAML.safe_load(content)
  rescue Psych::SyntaxError => e
    log.warn("Skipping #{repo} due to YAML error: #{e}")
    next
  end

  pipelines = config['pipelines'] || []
  repo_missing_public = []

  # It's a bummer to walk through this twice, but it's a very small list
  # and we need all the names to mmatch _private pipelines
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

      # if we have a private version of a pipeline, allow it if there's
      # also a public
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
        log.warn("#{pipeline_name} is marked as adhoc but isn't named as such")
        skipped_by_pattern['adhoc'] += 1
        next
      end

      total_pipeline_count += 1
      if !pipeline_details.is_a?(Hash) || pipeline_details['public'] != true
        repo_missing_public << pipeline_name
        private_pipeline_count += 1
      end
    end
  end

  next if repo_missing_public.empty?
  output(fh, "* #{repo}")
  repo_missing_public.each do |pname|
    output(fh, "    * #{pname}")
  end
  repos_with_private += 1

  next unless options[:make_prs_for].any? && options[:source_dir]
  pipelines_to_fix = repo_missing_public & options[:make_prs_for]
  next if pipelines_to_fix.empty?

  patched = patch_yaml_public_flag!(content, pipelines_to_fix)
  next unless patched

  repo_path = File.join(options[:source_dir], repo)
  unless Dir.exist?(repo_path)
    run_cmd!(
      ['sj', 'sclone', "#{options[:org]}/#{repo}"],
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
    next unless confirm == 'y'
  end

  run_cmd!(%w{sj spush}, cwd: repo_path, retries: 2)
  run_cmd!(%w{sj spr}, cwd: repo_path, retries: 2)
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
