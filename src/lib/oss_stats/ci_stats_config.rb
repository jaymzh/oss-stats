require 'mixlib/config'
require 'pathname'

module OssStats
  module CiStatsConfig
    extend Mixlib::Config

    default_branches ['main']
    default_days 30
    log_level :info
    ci_timeout 600
    github_api_endpoint nil
    github_token nil
    buildkite_token nil
    limit_gh_ops_per_minute nil
    include_list false
    organizations {}
    mode ['all']

    def self.config_file
      log.debug('config_file called')
      if OssStats::CiStatsConfig.config
        return OssStats::CiStatsConfig.config
      end

      [
        Dir.pwd,
        File.join(ENV['HOME'], '.config', 'oss_stats'),
        '/etc',
      ].each do |dir|
        f = File.join(dir, 'ci_stats_config.rb')
        log.debug("Checking if #{f} exists...")
        return f if ::File.exist?(f)
      end

      nil
    end
  end
end
