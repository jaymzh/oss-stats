#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'yaml'
require 'base64'
require 'uri'
require 'optparse'

require_relative 'utils/github_token'
require_relative 'utils/log'

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

# Command-line options
options = {
  skip_patterns: %w{adhoc release},
  repos: %w{},
  org: 'chef',
  log_level: :info,
}

OptionParser.new do |opts|
  opts.banner = 'Usage: check_gh_pipelines.rb [options]'

  opts.on(
    '--github-token TOKEN',
    'GitHub personal access token (or use GITHUB_TOKEN env var)',
  ) do |val|
    options[:github_token] = val
  end

  opts.on(
    '-l LEVEL',
    '--log-level LEVEL',
    'Set logging level to LEVEL. [default: info]',
  ) do |level|
    options[:log_level] = level.to_sym
  end

  opts.on(
    '--org ORG',
    "GitHub org name. [default: #{options[:org]}]",
  ) do |v|
    options[:org] = v
  end

  opts.on(
    '--repos REPO',
    'GitHub repositories name. Can specify comma-separated list and/or ' +
    ' use the option multiple times. Leave blank for all repos in the org.',
  ) do |v|
    options[:repos] += v.split(',')
  end

  opts.on(
    '--skip PATTERN',
    'Pipeline name substring to skip. Can specify a comma-separated list ' +
    ' and/or use the option multiple times. ' +
    "[default: #{options[:skip_patterns].join(',')}]",
  ) do |v|
    options[:skip_patterns] += v.split(',')
  end
end.parse!
log.level = options[:log_level] if options[:log_level]

options[:skip_patterns].uniq!
options[:repos].uniq!

github_token = get_github_token!(options)

total_pipeline_count = 0
private_pipeline_count = 0
repos_with_private = 0
skipped_by_pattern = Hash.new(0)

if options[:repos].empty?
  log.info("Fetching repos under '#{options[:org]}'...")
  page = 1
  loop do
    list = github_api_get(
      "/orgs/#{options[:org]}/repos?per_page=100&page=#{page}",
      github_token,
    )
    break if list.empty?

    options[:repos].concat(list.map { |r| r['name'] })
    page += 1
  end
  log.debug("Discovered these repos: #{options[:repos].join(', ')}")
end

options[:repos].each do |repo|
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

  pipelines.each do |pipeline_block|
    pipeline_block = { pipeline_block => {} } if pipeline_block.is_a?(String)

    pipeline_block.each do |pipeline_name, pipeline_details|
      skip_matched = options[:skip_patterns].find do |pat|
        pipeline_name.include?(pat)
      end

      if skip_matched
        skipped_by_pattern[skip_matched] += 1
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
  log.info("* #{repo}")
  repo_missing_public.each do |pname|
    log.info("    * #{pname}")
  end
  repos_with_private += 1
end

if total_pipeline_count > 0
  percentage_private = (
    (private_pipeline_count.to_f / total_pipeline_count.to_f) * 100
  ).round(2)
  log.info("\nTotal percentage of private pipelines: #{percentage_private}%")
  log.info(
    "  --> #{private_pipeline_count} out of #{total_pipeline_count} " +
    "across #{repos_with_private} repos",
  )

  if skipped_by_pattern.any?
    log.info('  --> Skipped pipelines:')
    skipped_by_pattern.each do |pattern, count|
      log.info("    - #{pattern}: #{count}")
    end
  end
else
  log.info('No pipelines found (excluding skipped patterns).')
end
