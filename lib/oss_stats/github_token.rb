# frozen_string_literal: true

require 'yaml'
require_relative 'log' # Assuming log is available similarly

# Fetches GitHub token from various sources.
#
# @param config [Mixlib::Config] The configuration object, expected to have `github_access_token`.
# @return [String] The GitHub token.
# Exits with error if token is not found.
def get_github_token!(config)
  token = config.github_access_token # Check if already set (e.g., by CLI --github-token or config file)
  return token if token

  token = ENV['GITHUB_TOKEN']
  if token
    config.github_access_token = token # Store it back
    return token
  end

  gh_hosts_path = File.expand_path('~/.config/gh/hosts.yml')
  if File.exist?(gh_hosts_path)
    begin
      gh_config = YAML.load_file(gh_hosts_path)
      # The structure might be {'github.com': {'oauth_token': 'TOKEN', ...}, ...}
      # or {'some.ghe.com': {'oauth_token': 'TOKEN', ...}}
      # We prioritize github.com but could extend to check config.github_api_endpoint domain
      token = gh_config['github.com']&.[]('oauth_token')
      if token
        config.github_access_token = token # Store it back
        return token
      end
    rescue Psych::SyntaxError => e
      Log.warn "Failed to parse GitHub CLI hosts file at #{gh_hosts_path}: #{e.message}"
    rescue StandardError => e
      Log.warn "Error reading GitHub CLI hosts file at #{gh_hosts_path}: #{e.message}"
    end
  end

  Log.fatal 'GitHub token not found. Please set GITHUB_TOKEN, use --github-token CLI option, set github_access_token in your ci_stats_config.rb, or ensure gh CLI is authenticated.'
  exit 1
end
