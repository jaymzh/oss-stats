require 'mixlib/config'
require_relative 'shared'

module OssStats
  module Config
    module Promises
      extend Mixlib::Config
      extend OssStats::Config::Shared

      db_file File.expand_path('./data/promises.sqlite3', Dir.pwd)
      dryrun false
      output nil
      log_level :info
      mode 'status'
      include_abandoned false

      def self.config_file
        find_config_file('promises_config.rb')
      end
    end
  end
end
