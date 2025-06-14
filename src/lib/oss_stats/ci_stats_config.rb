require 'mixlib/config'
require 'pathname'

module OssStats
  # Configuration module for the OSS Stats scripts.
  # Uses Mixlib::Config to provide a flexible way to set configuration options
  # via a config file, CLI options, or environment variables (where applicable).
  module CiStatsConfig
    extend Mixlib::Config

    default_branches ['main']
    default_days 30
    log_level :info
    ci_timeout 600
    github_api_endpoint nil
    github_token nil
    buildkite_token nil # Added buildkite_token
    limit_gh_ops_per_minute nil
    include_list false
    organizations {}
    mode ['all']

    # Determines the path to the configuration file.
    # It searches in the following locations in order:
    # 1. Path specified by `OssStats::CiStatsConfig.config` (e.g., via --config CLI).
    # 2. Current working directory (`./ci_stats_config.rb`).
    # 3. User's config directory (`~/.config/oss_stats/ci_stats_config.rb`).
    # 4. System-wide config directory (`/etc/ci_stats_config.rb`).
    #
    # @return [String, nil] The path to the found config file, or nil if not found.
    def self.config_file
      log.debug('config_file called')
      # If a config file path is explicitly set (e.g., by --config option), use that.
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
