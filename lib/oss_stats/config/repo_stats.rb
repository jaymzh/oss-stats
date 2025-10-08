require 'mixlib/config'
require_relative 'shared'

module OssStats
  module Config
    module RepoStats
      extend Mixlib::Config
      extend OssStats::Config::Shared

      # generally these should NOT be set, they override everything
      days nil
      branches nil
      top_n_stale nil
      top_n_oldest nil
      top_n_time_to_close nil
      top_n_most_broken_ci_days nil
      top_n_most_broken_ci_jobs nil
      top_n_stale_pr nil
      top_n_stale_issue nil
      top_n_oldest_pr nil
      top_n_oldest_issue nil
      top_n_time_to_close_pr nil
      top_n_time_to_close_issue nil

      # set these instead
      default_branches ['main']
      default_days 30

      log_level :info
      ci_timeout 600
      no_links false
      github_api_endpoint nil
      github_token nil
      github_org nil
      github_repo nil
      buildkite_token nil
      limit_gh_ops_per_minute nil
      include_list false
      count_unmerged_prs false
      mode ['all']
      organizations({})

      def self.config_file
        find_config_file('repo_stats_config.rb')
      end
    end
  end
end
