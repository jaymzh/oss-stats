require_relative '../log'

module OssStats
  module Config
    module Shared
      # a common method among all config parsers to
      # find the config file
      def find_config_file(filename)
        log.debug("#{name}: config_file called")

        # Check to see if `config` has been defined
        # in the current config, and if so, return that.
        #
        # Slight magic here, name will be, for example
        #   OssStats::Config::RepoStats
        # So we trip the first part and get just `RepoStats`,
        # then get the class, and check for config, akin to doing
        #
        #   if OssStats::Config::RepoStats.config
        #     return OssStats::Config::RepoStats.config
        #   end
        kls = name.sub('OssStats::Config::', '')
        config_class = OssStats::Config.const_get(kls)
        if config_class.config
          return config_class.config
        end

        # otherwise, we check CWD, XDG, and /etc.
        [
          Dir.pwd,
          File.join(ENV['HOME'], '.config', 'oss_stats'),
          '/etc',
        ].each do |dir|
          f = File.join(dir, filename)
          log.debug("[#{name}] Checking if #{f} exists...")
          return f if ::File.exist?(f)
        end

        nil
      end
    end
  end
end
