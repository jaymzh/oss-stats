require 'mixlib/config'
require_relative './log'

module OssStats
  module PromisesConfig
    extend Mixlib::Config

    db_file File.expand_path('./data/promises.sqlite3', Dir.pwd)
    dryrun false
    output nil
    log_level :info
    mode 'status'
    include_abandoned false

    def self.config_file
      log.debug('config_file called')
      if OssStats::PromisesConfig.config
        return OssStats::PromisesConfig.config
      end

      [
        Dir.pwd,
        File.join(ENV['HOME'], '.config', 'oss_stats'),
        '/etc',
      ].each do |dir|
        f = File.join(dir, 'promises_config.rb')
        log.debug("Checking if #{f} exists...")
        return f if ::File.exist?(f)
      end

      nil
    end
  end
end
