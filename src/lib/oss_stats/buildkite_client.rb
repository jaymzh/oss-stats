require 'graphql/client'
require 'graphql/client/http'
require 'date' # Ensure Date is available for parsing
require_relative 'log' # Ensure OssStats::Log is available

module OssStats
  # BuildkiteClient interacts with the Buildkite GraphQL API.
  # It requires the `graphql-client` gem.
  class BuildkiteClient
    attr_reader :token, :organization_slug

    # Configure the HTTP adapter for the GraphQL client.
    # This adapter will be used for all GraphQL requests.
    HTTP_ADAPTER = GraphQL::Client::HTTP.new(
      'https://graphql.buildkite.com/v1'
    ) do
      def headers(context)
        # Inject the Bearer token and a User-Agent into each request.
        # The `context` argument is not used here but is part of the method
        # signature.
        {
          'Authorization' => "Bearer #{context[:token]}",
          'User-Agent' => 'OssStats BuildkiteClient/1.0'
        }
      end
    end

    # Attempt to load the schema.
    # In a production environment, this schema might be fetched and cached,
    # or a pre-dumped schema.json could be used.
    # For now, we try to load it dynamically. If this fails in restricted
    # environments, a schema.json file would be the fallback.
    begin
      Schema = GraphQL::Client.load_schema(HTTP_ADAPTER)
    rescue SocketError, Net::OpenTimeout, Errno::ENETUNREACH => e
      # Fallback or error message if schema loading fails
      # This is a critical error for the client's operation.
      # For this refactoring, we'll log and re-raise, assuming schema must be
      # loadable. A more robust solution might involve loading from a local
      # file if HTTP fails.
      log.fatal "Failed to load Buildkite GraphQL schema: #{e.message}. " \
                "Ensure network connectivity or provide a local schema.json."
      # Re-raise or handle as appropriate for the application's startup
      # sequence. For now, let it potentially stop the application if schema
      # can't be loaded.
      raise "Buildkite GraphQL schema could not be loaded: #{e.message}"
    end

    # The main GraphQL client instance.
    Client = GraphQL::Client.new(schema: Schema, execute: HTTP_ADAPTER)

    # Define GraphQL queries as constants using the client.parse method.

    GetPipelineQuery = Client.parse <<-'GRAPHQL'
      query($slug: ID!) {
        pipeline(slug: $slug) {
          visibility
        }
      }
    GRAPHQL

    AllPipelinesQuery = Client.parse <<-'GRAPHQL'
      query($orgSlug: ID!, $first: Int!, $after: String) {
        organization(slug: $orgSlug) {
          pipelines(first: $first, after: $after) {
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

    GetPipelineBuildsQuery = Client.parse <<-'GRAPHQL'
      query(
        $pipelineSlug: ID!,
        $branch: [String!],
        $createdFrom: DateTime,
        $first: Int!,
        $after: String
      ) {
        pipeline(slug: $pipelineSlug) {
          builds(
            branch: $branch,
            createdAt: {from: $createdFrom},
            first: $first,
            after: $after,
            order: BUILD_ORDER_DESC
          ) {
            pageInfo {
              hasNextPage
              endCursor
            }
            edges {
              node {
                number
                state
                createdAt
                jobs(first: 100) { # Assuming a reasonable limit for jobs
                  edges {
                    node {
                      ... on JobTypeCommand {
                        label
                        state
                      }
                      # Can add other job types here if needed
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    def initialize(token, organization_slug)
      @token = token
      @organization_slug = organization_slug
      # @client is class constant `Client`.
      # HTTP_ADAPTER uses `context[:token]` passed in query calls.
    end

    def get_pipeline(pipeline_slug)
      full_slug = "#{@organization_slug}/#{pipeline_slug}"
      log.debug("Fetching pipeline: #{full_slug} using graphql-client")
      variables = { slug: full_slug }
      result = Client.query(
        GetPipelineQuery, variables:, context: { token: @token }
      )

      if result.errors.any?
        error_msg = result.errors.messages.values.join(', ')
        log.error("GraphQL errors for pipeline #{full_slug}: #{error_msg}")
        return nil
      end

      # .data can be nil if there are top-level errors or the query itself
      # returns nothing. Accessing .pipeline directly on a nil .data would
      # raise NoMethodError.
      return nil unless result.data

      pipeline_data = result.data.pipeline
      if pipeline_data.nil?
        log.debug("Pipeline #{full_slug} not found or no data returned.")
      end
      pipeline_data&.to_h # Convert GraphQL::Client::Schema::ObjectType
    rescue GraphQL::Client::Error => e # Catch client-specific errors
      log.error("GraphQL client error in get_pipeline for " \
                "#{full_slug}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      nil
    rescue StandardError => e # Catch other unexpected errors
      log.error("Unexpected error in get_pipeline for " \
                "#{full_slug}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      nil
    end

    def all_pipelines # rubocop:disable Metrics/AbcSize
      log.debug("Fetching all pipelines for org: #{@organization_slug} " \
                "using graphql-client")
      pipelines_acc = [] # Accumulator for pipeline nodes
      after_cursor = nil
      has_next_page = true

      while has_next_page
        variables = {
          orgSlug: @organization_slug,
          first: 50, # Number of items per page
          after: after_cursor
        }
        result = Client.query(
          AllPipelinesQuery, variables:, context: { token: @token }
        )

        if result.errors.any?
          error_msg = result.errors.messages.values.join(', ')
          log.error("GraphQL errors fetching all pipelines for " \
                    "#{@organization_slug}: #{error_msg}")
          break # Exit loop on error
        end

        unless result.data && result.data.organization && \
               result.data.organization.pipelines
          log.warn("No organization or pipelines data found for " \
                   "#{@organization_slug} in a page. Cursor: #{after_cursor}")
          break
        end

        org_data = result.data.organization
        current_pipelines_data = org_data.pipelines

        current_pipelines_data.edges.each do |edge|
          # Add pipeline data as hash
          pipelines_acc << edge.node.to_h if edge.node
        end

        page_info = current_pipelines_data.page_info
        has_next_page = page_info.has_next_page
        after_cursor = page_info.end_cursor
        if has_next_page
          log.debug("Pagination: hasNextPage: true, new_cursor: #{after_cursor}")
        end
      end

      pipelines_by_repo = Hash.new { |h, k| h[k] = [] }
      pipelines_acc.each do |pipeline|
        # Ensure 'repository' and 'url' are present before trying to access
        repo_url = pipeline.dig('repository', 'url')&.gsub('.git', '')
        next unless repo_url

        pipelines_by_repo[repo_url] << {
          slug: pipeline['slug'],
          visibility: pipeline['visibility']
        }
      end
      pipelines_by_repo
    rescue GraphQL::Client::Error => e
      log.error("GraphQL client error in all_pipelines for " \
                "#{@organization_slug}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      {} # Return empty hash on error
    rescue StandardError => e
      log.error("Unexpected error in all_pipelines for " \
                "#{@organization_slug}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      {}
    end

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def get_pipeline_builds(pipeline_slug, branch_name, since_date)
      full_slug = "#{@organization_slug}/#{pipeline_slug}"
      log.debug(
        "Fetching builds for pipeline: #{full_slug}, " \
        "branch: #{branch_name}, since: #{since_date} using graphql-client"
      )
      failed_builds_jobs = []
      after_cursor = nil
      has_next_page = true
      # Ensure since_date is in ISO8601 format for the GraphQL query
      iso_since_date = if since_date.is_a?(String)
                         since_date
                       else
                         since_date.to_datetime.rfc3339
                       end

      while has_next_page
        variables = {
          pipelineSlug: full_slug,
          # API expects an array of strings for branches
          branch: [branch_name].compact,
          createdFrom: iso_since_date,
          first: 50, # Page size
          after: after_cursor
        }
        result = Client.query(
          GetPipelineBuildsQuery, variables:, context: { token: @token }
        )

        if result.errors.any?
          error_msg = result.errors.messages.values.join(', ')
          log.error("GraphQL errors for builds of #{full_slug}, " \
                    "branch #{branch_name}: #{error_msg}")
          break # Exit loop on error
        end

        unless result.data && result.data.pipeline && \
               result.data.pipeline.builds
            errors = result.errors.messages.values.join(', ')
            log.warn("No pipeline or builds data found for #{full_slug}, " \
                     "branch #{branch_name}, since: #{iso_since_date} " \
                     "in a page. Cursor: #{after_cursor}. Errors: #{errors}")
            break
        end

        builds_connection = result.data.pipeline.builds

        builds_connection.edges.each do |build_edge|
          build = build_edge.node
          next unless build # Skip if build node is nil

          build_created_at = Date.parse(build.created_at)

          # Ensure jobs is not nil and has edges
          next unless build.jobs && build.jobs.edges

          build.jobs.edges.each do |job_edge|
            job = job_edge.node
            # Ensure job is not nil, has a state, and state is FAILED
            next unless job && job.respond_to?(:state) && \
                        job.state == 'FAILED'

            failed_builds_jobs << {
              # Use label if available
              name: job.respond_to?(:label) ? job.label : 'Unknown Job',
              date: build_created_at.strftime('%Y-%m-%d')
            }
          end
        end

        page_info = builds_connection.page_info
        has_next_page = page_info.has_next_page
        after_cursor = page_info.end_cursor
        if has_next_page
          log.debug("Builds Pagination: hasNextPage: true, " \
                    "new_cursor: #{after_cursor}")
        end
      end
      log.debug("Found #{failed_builds_jobs.length} failed jobs for " \
                "#{full_slug}, branch: #{branch_name}, " \
                "since: #{iso_since_date}")
      failed_builds_jobs
    rescue GraphQL::Client::Error => e
      log.error("GraphQL client error in get_pipeline_builds for " \
                "#{full_slug}, branch #{branch_name}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      []
    rescue StandardError => e
      log.error("Unexpected error in get_pipeline_builds for " \
                "#{full_slug}, branch #{branch_name}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      []
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Old execute_graphql_query method is no longer needed and has been removed.
  end
end

# Helper method for logging, assuming a simple global logger for now.
# This could be replaced with a more sophisticated logging setup
# (e.g., Mixlib::Log).
def log
  OssStats::Log.instance
end
