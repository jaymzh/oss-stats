def get_buildkite_token(options)
  options[:buildkite_token] || ENV['BUILDKITE_TOKEN'] || nil
end

def get_buildkite_token!(options)
  token = get_buildkite_token(options)
  unless token
    raise ArgumentError,
      'Buildkite token not found. Pass with --buildkite-token or set ' +
      'BUILDKITE_TOKEN env var.'
  end
  token
end
