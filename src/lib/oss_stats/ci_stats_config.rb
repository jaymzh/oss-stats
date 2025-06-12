require 'mixlib/config'
require 'pathname'

module OssStats
  module CiStatsConfig
    extend Mixlib::Config

    # Default global settings
    # default :default_org, 'chef' # No longer hardcoded, must come from file or CLI
    # default :default_repo, 'chef' # No longer hardcoded, must come from file or CLI
    default :default_branches, ['main']
    default :default_days, 30
    default :log_level, :info
    default :ci_timeout, 600 # 10 minutes in seconds
    # default :skip_ci, false # Option removed
    # default :dry_run, false # Option removed
    default :github_api_endpoint, nil
    default :github_access_token, nil # Stores GITHUB_TOKEN
    default :limit_gh_ops_per_minute, nil # Float, e.g., 60.0
    default :include_list, false # For PR/Issue listing in output

    # Configuration for organizations and their repositories
    default :organizations, {}

    # Config file path setting itself
    # This is not a typical Mixlib::Config attribute but used by the script's logic
    # to track the loaded config file.
    config_attr :config_file_loaded # To store the path of the file that was loaded

    # Logic to find the configuration file
    # rubocop:disable Style/ClassVars
    @@config_file_path_explicitly_set = nil
    # rubocop:enable Style/ClassVars

    class << self
      # Called by OptionParser when --config is used
      def set_config_file_path(path)
        # rubocop:disable Style/ClassVars
        @@config_file_path_explicitly_set = path
        # rubocop:enable Style/ClassVars
      end

      def config_file_to_load
        # rubocop:disable Style/ClassVars
        return @@config_file_path_explicitly_set if @@config_file_path_explicitly_set

        # Standard search paths
        # Ordered from most specific to least specific generally
        paths_to_check = [
          Pathname.new(Dir.pwd).join('ci_stats_config.rb'),
          Pathname.new(Dir.home).join('.config', 'oss-stats', 'ci_stats_config.rb'),
          Pathname.new(Dir.home).join('.chef', 'ci_stats_config.rb'), # Legacy Chef-style path
          Pathname.new('/etc/oss-stats/ci_stats_config.rb')
        ]
        # Consider adding project root default if desired:
        # paths_to_check.unshift(Pathname.new(File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'config', 'ci_stats_config.rb'))))

        paths_to_check.each do |path|
          return path.to_s if path.exist?
        end
        nil # No config file found in default locations
        # rubocop:enable Style/ClassVars
      end
    end
  end
end
