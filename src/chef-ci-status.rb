#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'yaml'
require 'octokit'
require 'set'


# Get GitHub token
def get_github_token
  config_path = File.expand_path('~/.config/gh/hosts.yml')
  if File.exist?(config_path)
    config = YAML.load_file(config_path)
    return config.dig('github.com', 'oauth_token')
  end
  nil
end

def get_failed_tests_from_ci(client, options, branches)
  repo = "#{options[:owner]}/#{options[:repo]}"
  cutoff_date = Date.today - options[:days]
  today = Date.today
  failed_tests = Hash.new { |h, k| h[k] = {} }

  branches.each do |branch|
    puts "Checking workflow runs for branch: #{branch}" if options[:verbose]

    # Get all workflows for the repository
    workflows = client.workflows(repo).workflows
    workflows.each do |workflow|
      workflow_runs = []
      page = 1

      loop do
        runs = client.workflow_runs(repo, workflow.id, branch: branch, status: 'completed', per_page: 100, page: page)
        break if runs.workflow_runs.empty?

        workflow_runs.concat(runs.workflow_runs)
        break if runs.workflow_runs.last.created_at.to_date < cutoff_date

        page += 1
      end

      workflow_runs.sort_by! { |run| run.created_at }
      last_failure_date = {}

      workflow_runs.each do |run|
        run_date = run.created_at.to_date
        next if run_date < cutoff_date

        puts "Checking workflow run: #{run.id} at #{run.created_at} on branch #{branch}" if options[:verbose]
        jobs = client.workflow_run_jobs(repo, run.id).jobs

        jobs.each do |job|
          puts "  Checking job: #{job.name} (Status: #{job.conclusion})" if options[:verbose]

          failed_tests[branch][job.name] ||= Set.new if job.conclusion == 'failure'
          last_date = last_failure_date[job.name]

          if last_date
            while last_date < run_date
              puts "  -> Filling in fail date for #{job.name}: #{last_date}" if options[:verbose]
              failed_tests[branch][job.name] << last_date
              last_date += 1
            end
          end

          if job.conclusion == 'failure'
            puts "  -> First failure of #{job.name}" if options[:verbose] && !last_failure_date.key?(job.name)
            failed_tests[branch][job.name] << run_date
            last_failure_date[job.name] = run_date
          elsif job.conclusion == 'success'
            last_failure_date.delete(job.name)
          end
        rescue StandardError => e
          puts "Error getting jobs for run #{run.id}: #{e}"
          next
        end
      end

      last_failure_date.each do |job_name, last_date|
        while last_date < today
          puts "Filling in fail date until today for #{job_name}: #{last_date}" if options[:verbose]
          failed_tests[branch][job_name] << last_date
          last_date += 1
        end
      end
    end
  end

  failed_tests
end

options = {
  owner: 'chef',
  repo: 'chef',
  branches: 'chef-18,main',
  days: 30,
  verbose: false
}

OptionParser.new do |opts|
  opts.banner = 'Usage: script.rb [options]'

  opts.on('--owner OWNER', 'GitHub owner/org name') { |v| options[:owner] = v }
  opts.on('--repo REPO', 'GitHub repository name') { |v| options[:repo] = v }
  opts.on('--branches BRANCHES', 'Comma-separated list of branches') { |v| options[:branches] = v }
  opts.on('--days DAYS', Integer, 'Number of days to analyze') { |v| options[:days] = v }
  opts.on('-v', '--verbose', 'Enable verbose output') { options[:verbose] = true }
end.parse!

github_token = get_github_token
raise 'GitHub token not found in ~/.config/gh/hosts.yml' unless github_token

client = Octokit::Client.new(access_token: github_token)

branches = options[:branches].split(',')
test_failures = get_failed_tests_from_ci(client, options, branches)
puts "Days each job was broken in the last #{options[:days]} days:"
test_failures.each do |branch, jobs|
  puts "\nBranch: #{branch}"
  if jobs.empty?
    puts '  No job failures found.'
  else
    jobs.sort.each do |job, dates|
      puts "  #{job}: #{dates.size} days"
    end
  end
end
