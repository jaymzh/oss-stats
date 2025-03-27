#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'yaml'
require 'base64'
require 'uri'
require 'optparse'

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

def get_expeditor_config(repo, token)
  path = "/repos/#{ORG}/#{repo}/contents/.expeditor/config.yml"
  res = github_api_get(path, token)
  Base64.decode64(res['content'])
rescue
  nil
end

# Command-line options
options = {
  skip_patterns: %w{adhoc release}, # default
}

OptionParser.new do |opts|
  opts.banner = 'Usage: check_gh_pipelines.rb [options]'

  opts.on(
    '--skip PATTERN',
    'Pipeline name substring to skip (can be used multiple times)',
  ) do |val|
    options[:skip_patterns] << val unless options[:skip_patterns].include?(val)
  end

  opts.on(
    '--token TOKEN',
    'GitHub personal access token (or use GITHUB_TOKEN env var)',
  ) do |val|
    options[:token] = val
  end
end.parse!

GITHUB_TOKEN = options[:token] || ENV['GITHUB_TOKEN']
unless GITHUB_TOKEN
  raise 'Missing GitHub token. Set --token or GITHUB_TOKEN env.'
end

ORG = 'chef'.freeze

total_pipeline_count = 0
private_pipeline_count = 0
repos_with_private = 0
skipped_by_pattern = Hash.new(0)

# Fetch all repos
repos = []
page = 1

puts "Fetching repos under '#{ORG}'..."

loop do
  list = github_api_get("/orgs/#{ORG}/repos?per_page=100&page=#{page}",
GITHUB_TOKEN)
  break if list.empty?

  repos.concat(list.map { |r| r['name'] })
  page += 1
end

repos.each do |repo|
  content = get_expeditor_config(repo, GITHUB_TOKEN)
  next unless content

  begin
    config = YAML.safe_load(content)
  rescue Psych::SyntaxError => e
    warn "Skipping #{repo} due to YAML error: #{e}"
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
  puts "* #{repo}"
  repo_missing_public.each do |pname|
    puts "    * #{pname}"
  end
  repos_with_private += 1
end

if total_pipeline_count > 0
  percentage_private = (
    (private_pipeline_count.to_f / total_pipeline_count.to_f) * 100
  ).round(2)
  puts "\nTotal percentage of private pipelines: #{percentage_private}%"
  puts "  --> #{private_pipeline_count} out of #{total_pipeline_count} " +
       "across #{repos_with_private} repos"

  if skipped_by_pattern.any?
    puts ' -> Skipped pipelines:'
    skipped_by_pattern.each do |pattern, count|
      puts "    - #{pattern}: #{count}"
    end
  end
else
  puts 'No pipelines found (excluding skipped patterns).'
end
