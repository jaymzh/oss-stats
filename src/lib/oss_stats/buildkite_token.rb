require_relative 'ci_stats_config' # Ensure CiStatsConfig is available
require_relative 'log' # Ensure log is available

# Fetches the Buildkite token.
# Priority:
# 1. OssStats::CiStatsConfig.buildkite_token (set by CLI or config file)
# 2. BUILDKITE_API_TOKEN environment variable
#
# @param config [OssStats::CiStatsConfig] The configuration object (optional, defaults to global config).
# @return [String, nil] The Buildkite token if found, otherwise nil.
def get_buildkite_token(config = OssStats::CiStatsConfig)
  token = config.buildkite_token
  if token
    log.debug('Using Buildkite token from CiStatsConfig')
    return token
  end

  token = ENV['BUILDKITE_API_TOKEN'] # Standard ENV var name for Buildkite
  if token
    log.debug('Using Buildkite token from BUILDKITE_API_TOKEN environment variable')
    return token
  end

  log.debug('Buildkite token not found in CiStatsConfig or ' \
            'BUILDKITE_API_TOKEN environment variable.')
  nil
end

# Fetches the Buildkite token and raises an error if not found.
#
# @param config [OssStats::CiStatsConfig] The configuration object (optional, defaults to global config).
# @return [String] The Buildkite token.
# @raise [ArgumentError] If the token is not found.
def get_buildkite_token!(config = OssStats::CiStatsConfig)
  token = get_buildkite_token(config)
  unless token
    # Log error before raising, as the raise might be caught and not logged by caller
    error_message = 'Buildkite token not found. Set via --buildkite-token CLI option, ' \
                    'in ci_stats_config.rb, or as BUILDKITE_API_TOKEN environment variable.'
    log.error(error_message)
    raise ArgumentError, error_message
  end
  token
end
