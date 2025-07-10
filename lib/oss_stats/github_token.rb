require_relative 'log'

# looks for :github_token in `options`, falling back to
# $GITHUB_TOKEN, and then gh's auth.
def get_github_token(options)
  if options[:github_token]
    log.debug('Using GH token from CLI')
    return options[:github_token]
  elsif ENV['GITHUB_TOKEN']
    log.debug('Using GH token from env')
    return ENV['GITHUB_TOKEN']
  end

  config_path = File.expand_path('~/.config/gh/hosts.yml')
  if File.exist?(config_path)
    config = YAML.load_file(config_path)
    token = config.dig('github.com', 'oauth_token')
    if token
      log.debug('Using GH token from gh cli config')
      return token
    end
  end
  nil
end

def get_github_token!(options)
  token = get_github_token(options)
  unless token
    raise ArgumentError,
      'GitHub token is missing. Please provide a token using ' +
      '--github-token, or set $GITHUB_TOKEN, or run `gh auth login`'
  end
  token
end
