require 'mixlib/config'
require_relative 'shared'

module OssStats
  module Config
    module RepoStats
      extend Mixlib::Config
      extend OssStats::Config::Shared

      # generally this shouldn't be set, it overrides everything
      days nil
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
      mode ['all']
      organizations({})

      def self.config_file
        find_config_file('repo_stats_config.rb')
      end
    end
  end
end
