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
      query = <<~GRAPHQL
        query {
          pipeline(slug: "#{@organization_slug}/#{pipeline_slug}") {
            visibility
          }
        }
      GRAPHQL

      http = Net::HTTP.new(@graphql_endpoint.host, @graphql_endpoint.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(@graphql_endpoint.request_uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      request.body = { query: }.to_json

      begin
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          # Consider logging response.body for more details in a real app
          raise "Buildkite API request failed with status #{response.code}: #{response.message}"
        end

        parsed_response = JSON.parse(response.body)

        if parsed_response['errors']
          # Consider logging the full error array in a real app
          raise "Buildkite API returned errors: #{parsed_response['errors'].map { |e| e['message'] }.join(', ')}"
        end

        visibility = parsed_response.dig('data', 'pipeline', 'visibility')
        unless visibility
          raise "Could not extract pipeline visibility from Buildkite API response. Response: #{response.body}"
        end

        visibility
      rescue Net::HTTPExceptions => e
        # Handles various network errors like timeout, connection refused, etc.
        raise "Network error while connecting to Buildkite API: #{e.message}"
      rescue JSON::ParserError => e
        raise "Error parsing JSON response from Buildkite API: #{e.message}. Response body: #{response&.body}"
      rescue StandardError => e
        # Catch any other unexpected errors during the process
        # This ensures we don't let specific errors above mask a more general one
        # or if an error occurs outside the specific rescues (e.g. in URI parsing if endpoint was dynamic)
        raise "An unexpected error occurred: #{e.message}"
      end
    end
  end
end
