require 'net/http'
require 'json'
require 'uri'

module OssStats
  class BuildkiteClient
    attr_reader :token, :organization_slug

    def initialize(token, organization_slug)
      @token = token
      @organization_slug = organization_slug
      @graphql_endpoint = URI('https://graphql.buildkite.com/v1')
    end

    def get_pipeline(pipeline_slug)
      log.debug("Fetching pipeline: #{@organization_slug}/#{pipeline_slug}")
      query = <<~GRAPHQL
        query {
          pipeline(slug: "#{@organization_slug}/#{pipeline_slug}") {
            visibility
          }
        }
      GRAPHQL

      response_data = execute_graphql_query(query)
      pipeline_data = response_data.dig('data', 'pipeline')
      if pipeline_data.nil? && response_data['data'].key?('pipeline')
        # The query returned, and the 'pipeline' key exists but is null,
        # meaning the pipeline was not found by Buildkite.
        log.debug(
          "Pipeline #{@organization_slug}/#{pipeline_slug} not found.",
        )
      elsif pipeline_data.nil? && response_data['errors']
        # Errors occurred, already logged by execute_graphql_query,
        # but we might want to note the slug it failed for.
        log.warn(
          "Failed to fetch pipeline #{@organization_slug}/#{pipeline_slug}" +
          'due to API errors',
        )
      end
      pipeline_data
    rescue StandardError => e
      log.error(
        'Error in get_pipeline for slug ' +
        "#{@organization_slug}/#{pipeline_slug}: #{e.message}",
      )
      nil
    end

    def all_pipelines
      pipelines = []
      after_cursor = nil
      has_next_page = true

      while has_next_page
        query = <<~GRAPHQL
          query {
            organization(slug: "#{@organization_slug}") {
              pipelines(
                first: 50,
                after: #{after_cursor ? "\"#{after_cursor}\"" : 'null'}
              ) {
                edges {
                  node {
                    slug
                    repository {
                      url
                    }
                    visibility
                  }
                }
                pageInfo {
                  endCursor
                  hasNextPage
                }
              }
            }
          }
        GRAPHQL

        response_data = execute_graphql_query(query)
        current_pipelines = response_data.dig(
          'data', 'organization', 'pipelines', 'edges'
        )
        pipelines.concat(current_pipelines.map do |edge|
                           edge['node']
                         end) if current_pipelines

        page_info = response_data.dig(
          'data', 'organization', 'pipelines', 'pageInfo'
        )
        has_next_page = page_info['hasNextPage']
        after_cursor = page_info['endCursor']
      end

      pipelines_by_repo = Hash.new { |h, k| h[k] = [] }
      pipelines.each do |pipeline|
        repo_url = pipeline.dig('repository', 'url').gsub('.git', '')
        next unless repo_url

        pipelines_by_repo[repo_url] << {
          slug: pipeline['slug'],
          visibility: pipeline['visibility'],
        }
      end

      pipelines_by_repo
    end

    private

    def execute_graphql_query(query)
      http = Net::HTTP.new(@graphql_endpoint.host, @graphql_endpoint.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(@graphql_endpoint.request_uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      request.body = { query: }.to_json

      begin
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          error_message = 'Buildkite API request failed with status ' \
                          "#{response.code}: #{response.message}"
          log.error(error_message)
          raise error_message
        end

        parsed_response = JSON.parse(response.body)

        if parsed_response['errors']
          # Log each error for better context if multiple errors are returned
          error_details = parsed_response['errors'].map do |e|
            msg = e['message']
            path = e['path'] ? " (path: #{e['path'].join(' -> ')})" : ''
            "#{msg}#{path}"
          end.join('; ')
          error_message = "Buildkite API returned errors: #{error_details}"
          log.error(error_message)
          # Also log the full error response for detailed debugging
          log.debug(
            "Full Buildkite error response: #{parsed_response['errors']}",
          )
          raise error_message
        end
        parsed_response
      rescue Net::HTTPExceptions => e
        error_message =
          "Network error connecting to Buildkite API: #{e.message}"
        log.error(error_message)
        raise error_message
      rescue JSON::ParserError => e
        error_message = "Error parsing JSON from Buildkite API: #{e.message}."
        log.error(error_message)
        log.debug("Problematic JSON response body: #{response&.body}")
        raise error_message
      rescue StandardError => e
        error_message =
          "Unexpected error during Buildkite API call: #{e.message}"
        log.error(error_message)
        raise error_message
      end
    end
  end
end
