require 'mixlib/log'

module Mixlib
  module Log
    class Formatter
      def call(severity, _time, _progname, msg)
        if severity == 'INFO'
          "#{msg2str(msg)}\n"
        else
          "#{severity}: #{msg2str(msg)}\n"
        end
      end
    end
  end
end

module OssStats
  class Log
    extend Mixlib::Log
  end
end

def log
  OssStats::Log
end
