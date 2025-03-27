# looks for :github_token in `options`, falling back to
# $GITHUB_TOKEN, and then gh's auth.
def get_github_token(options)
  return options[:github_token] if options[:github_token]
  return ENV['GITHUB_TOKEN'] if ENV['GITHUB_TOKEN']

  config_path = File.expand_path('~/.config/gh/hosts.yml')
  if File.exist?(config_path)
    config = YAML.load_file(config_path)
    return config.dig('github.com', 'oauth_token')
  end
  nil
end

def get_github_token!(options)
  token = get_github_token(options)
  unless token
    raise 'GitHub token is missing. Please provide a token using ' +
          '--github-token, or set $GITHUB_TOKEN, or run `gh auth login`'
  end
  token
end
