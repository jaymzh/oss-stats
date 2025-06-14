# Retrieves the Buildkite token.
# It first checks the options hash, then environment variables.
# Returns the token string or nil if not found.
def get_buildkite_token(options)
  options[:buildkite_token] || ENV['BUILDKITE_TOKEN'] || nil
end

# Retrieves the Buildkite token, raising an error if not found.
# This ensures a token is available where required.
# Returns the token string.
# Raises ArgumentError if the token cannot be found.
def get_buildkite_token!(options)
  token = get_buildkite_token(options)
  unless token
    error_message = 'Buildkite token not found. Pass with --buildkite-token ' \
                    'or set BUILDKITE_TOKEN env var.'
    raise ArgumentError, error_message
  end
  token
end
