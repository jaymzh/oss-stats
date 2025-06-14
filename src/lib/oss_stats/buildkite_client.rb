require 'graphql/client'
require 'graphql/client/http'
require 'date' # Ensure Date is available for parsing
require_relative 'log' # Ensure OssStats::Log is available

module OssStats
  # BuildkiteClient interacts with the Buildkite GraphQL API.
  # It requires the `graphql-client` gem and a schema.json file.
  class BuildkiteClient
    attr_reader :token, :organization_slug

    def initialize(token, organization_slug)
      @token = token
      @organization_slug = organization_slug

      schema_path = File.expand_path('schema.json', __dir__)
      unless File.exist?(schema_path)
        err_msg = "GraphQL schema file not found at #{schema_path}. " \
                  "Please run 'ruby fetch_schema.rb' to generate it."
        log.fatal(err_msg)
        raise LoadError, err_msg
      end

      @schema = GraphQL::Client.load_schema(schema_path)

      @http_adapter = GraphQL::Client::HTTP.new(
        'https://graphql.buildkite.com/v1'
      ) do
        define_method :headers do |context|
          {
            'Authorization' => "Bearer #{context[:token]}",
            'User-Agent' => 'OssStats BuildkiteClient/1.0'
          }
        end
      end

      @client = GraphQL::Client.new(schema: @schema, execute: @http_adapter)
    end

    def get_pipeline(pipeline_slug)
      full_slug = "#{@organization_slug}/#{pipeline_slug}"
      log.debug("Fetching pipeline: #{full_slug} using graphql-client")
      variables = { slug: full_slug }
      result = @client.query(
        get_pipeline_query_definition,
        variables:,
        context: { token: @token }
      )

      if result.errors.any?
        error_msg = result.errors.messages.values.join(', ')
        log.error("GraphQL errors for pipeline #{full_slug}: #{error_msg}")
        return nil
      end

      return nil unless result.data

      pipeline_data = result.data.pipeline
      if pipeline_data.nil?
        log.debug("Pipeline #{full_slug} not found or no data returned.")
      end
      pipeline_data&.to_h
    rescue GraphQL::Client::Error => e
      log.error("GraphQL client error in get_pipeline for " \
                "#{full_slug}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      nil
    rescue StandardError => e
      log.error("Unexpected error in get_pipeline for " \
                "#{full_slug}: #{e.message}")
      log.debug(e.backtrace.join("\n"))
      nil
    end

    def all_pipelines # rubocop:disable Metrics/AbcSize
      log.debug("Fetching all pipelines for org: #{@organization_slug} " \
                "using graphql-client")
      pipelines_acc = []
      after_cursor = nil
      has_next_page = true

      while has_next_page
        variables = {
          orgSlug: @organization_slug,
          first: 50,
          after: after_cursor
        }
        result = @client.query(
          all_pipelines_query_definition,
          variables:,
          context: { token: @token }
        )

        if result.errors.any?
          error_msg = result.errors.messages.values.join(', ')
          log.error("GraphQL errors fetching all pipelines for " \
                    "#{@organization_slug}: #{error_msg}")
          break
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
      {}
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
      iso_since_date = if since_date.is_a?(String)
                         since_date
                       else
                         since_date.to_datetime.rfc3339
                       end

      while has_next_page
        variables = {
          pipelineSlug: full_slug,
          branch: [branch_name].compact,
          createdFrom: iso_since_date,
          first: 50,
          after: after_cursor
        }
        result = @client.query(
          get_pipeline_builds_query_definition,
          variables:,
          context: { token: @token }
        )

        if result.errors.any?
          error_msg = result.errors.messages.values.join(', ')
          log.error("GraphQL errors for builds of #{full_slug}, " \
                    "branch #{branch_name}: #{error_msg}")
          break
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
          next unless build

          build_created_at = Date.parse(build.created_at)
          next unless build.jobs && build.jobs.edges

          build.jobs.edges.each do |job_edge|
            job = job_edge.node
            next unless job && job.respond_to?(:state) && \
                        job.state == 'FAILED'

            failed_builds_jobs << {
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

    private

    def get_pipeline_query_definition
      @get_pipeline_query_definition ||= @client.parse <<-'GRAPHQL'
        query($slug: ID!) {
          pipeline(slug: $slug) {
            visibility
          }
        }
      GRAPHQL
    end

    def all_pipelines_query_definition
      @all_pipelines_query_definition ||= @client.parse <<-'GRAPHQL'
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
    end

    def get_pipeline_builds_query_definition
      @get_pipeline_builds_query_definition ||= @client.parse <<-'GRAPHQL'
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
    end
  end
end

# Helper method for logging, assuming a simple global logger for now.
# This could be replaced with a more sophisticated logging setup
# (e.g., Mixlib::Log).
def log
  OssStats::Log.instance
end
