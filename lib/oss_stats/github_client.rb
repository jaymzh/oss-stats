require 'net/http'
require 'json'
require 'uri'

# In general, we use octokit, but there are a few places were
# we cannot, and this handles those cases
module OssStats
  class GitHubClient
    attr_reader :token

    def initialize(token)
      @token = token
      @endpoint = 'https://api.github.com'
    end

    def pr_statuses(pr)
      url = pr['statuses_url']
      return [] unless url

      uri = URI(url)
      get(uri.path)
    end

    def recent_prs(org, repo, n = 10)
      prs_path = "/repos/#{org}/#{repo}/pulls"
      pr_query_params = {
        state: 'open', sort: 'updated', direction: 'desc', per_page: n
      }
      pr_uri = URI(prs_path)
      pr_uri.query = URI.encode_www_form(pr_query_params)
      get(pr_uri.path)
    rescue StandardError => e
      log.error("Error fetching PRs for #{repo_url}: #{e.message}")
      []
    end

    def get(path)
      log.trace("github_api_get: Attempting to parse URI with path: '#{path}'")
      uri = URI("#{@endpoint}#{path}")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@token}"
      req['Accept'] = 'application/vnd.github+json'
      req['User-Agent'] = 'private-pipeline-checker'

      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(req)
      end
      unless res.is_a?(Net::HTTPSuccess)
        raise "GitHub API error: #{res.code} #{res.body}"
      end

      JSON.parse(res.body)
    end
  end
end
