def get_buildkite_token(options)
  return options[:buildkite_token] if options[:buildkite_tokne]
  return ENV['BUILDKITE_API_TOKEN'] if ENV['BUILDKITE_API_TOKEN']
  nil
end

def get_buildkite_token!(config = OssStats::CiStatsConfig)
  token = get_buildkite_token(config)
  unless token
    raise ArgumentError,
      'Buildkite token not found. Set via --buildkite-token CLI option, ' +
      'in ci_stats_config.rb, or as BUILDKITE_API_TOKEN environment variable.'
  end
  token
end
