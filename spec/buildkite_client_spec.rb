require 'spec_helper'
require 'oss_stats/buildkite_client'
require 'graphql/client' # Required for GraphQL::Client::Response, etc.

# For now, to avoid test failures due to the schema loading HTTP request,
# we will keep WebMock enabled ONLY for the schema loading URL.
# All other mocks will be for `Client.query`.
# This is a pragmatic compromise.
require 'webmock/rspec' # Keep for schema loading if necessary
WebMock.disable_net_connect!(allow_localhost: true)
# Allow schema introspection query
# This regex might need to be more specific if other POSTs are made
allowed_schema_url = 'https://graphql.buildkite.com/v1'
WebMock.stub_request(:post, allowed_schema_url).to_return(lambda { |request|
  # A very basic introspection query response.
  # In a real scenario, you'd use a fixture for this.
  # This is just to make GraphQL::Client.load_schema(HTTP_ADAPTER) not fail.
  if request.body.include?("IntrospectionQuery")
    return {
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        data: { __schema: { queryType: { name: "Query" }, types: [] } }
      }.to_json
    }
  end
  # For other queries, it should be mocked specifically by tests later.
  # Returning a generic error or an empty success to avoid test pollution.
  error_body = {
    errors: [{ message: "Unhandled GraphQL request in schema loading mock" }]
  }
  return { status: 418, body: error_body.to_json }
})


describe OssStats::BuildkiteClient do
  let(:token) { 'fake_buildkite_token' }
  let(:organization_slug) { 'test-org' }
  # Short pipeline slug, not org/pipeline
  let(:pipeline_slug) { 'test-pipeline' }
  # Used in queries
  let(:full_pipeline_slug) { "#{organization_slug}/#{pipeline_slug}" }
  # Renamed to avoid conflict with GraphQL::Client
  let(:bk_client) { described_class.new(token, organization_slug) }

  # Helper to create a GraphQL::Client::Response
  def mock_graphql_client_response(data: nil, errors: nil)
    mock_errors_obj = nil
    if errors && errors.any?
      error_hashes = errors.map { |msg| { "message" => msg } }
      mock_errors_obj = GraphQL::Client::Errors.new(
        data: nil,
        original_hash: { "errors" => error_hashes },
        messages: error_hashes.map { |h| h["message"] }
      )
    end
    GraphQL::Client::Response.new(
      data: data&.deep_stringify_keys,
      errors: mock_errors_obj,
      extensions: nil
    )
  end


  describe '#get_pipeline' do
    it 'returns pipeline visibility when successful' do
      mock_data = { "pipeline" => { "visibility" => "PUBLIC" } }
      response = mock_graphql_client_response(data: mock_data)
      expected_vars = { slug: full_pipeline_slug }

      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(
          OssStats::BuildkiteClient::GetPipelineQuery,
          variables: expected_vars,
          context: { token: token }
        ).and_return(response)

      result = bk_client.get_pipeline(pipeline_slug)
      expect(result).to eq({ "visibility" => "PUBLIC" })
    end

    it 'returns nil when pipeline is not found' do
      # Simulate not found
      response = mock_graphql_client_response(data: { "pipeline" => nil })
      expected_vars = { slug: full_pipeline_slug }
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(
          OssStats::BuildkiteClient::GetPipelineQuery,
          variables: expected_vars,
          context: { token: token }
        ).and_return(response)

      expect(bk_client.get_pipeline(pipeline_slug)).to be_nil
    end

    it 'returns nil and logs errors when GraphQL errors occur' do
      response = mock_graphql_client_response(errors: ["Server error"])
      expected_vars = { slug: full_pipeline_slug }
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(
          OssStats::BuildkiteClient::GetPipelineQuery,
          variables: expected_vars,
          context: { token: token }
        ).and_return(response)

      error_log_msg = /GraphQL errors for pipeline #{full_pipeline_slug}: Server error/
      expect(OssStats::Log.instance).to receive(:error).with(error_log_msg)
      expect(bk_client.get_pipeline(pipeline_slug)).to be_nil
    end
  end

  describe '#all_pipelines' do
    let(:mock_pipeline_edge) do |slug, repo_url, visibility|
      {
        "node" => {
          "slug" => "#{organization_slug}/#{slug}",
          "repository" => { "url" => repo_url },
          "visibility" => visibility
        }
      }
    end

    it 'fetches all pipelines with pagination' do
      page1_data = { "organization" => { "pipelines" => {
        "edges" => [
          mock_pipeline_edge.call(
            "pipe1", "git://github.com/test-org/repo1.git", "PUBLIC"
          )
        ],
        "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor1" }
      }}}
      page2_data = { "organization" => { "pipelines" => {
        "edges" => [
          mock_pipeline_edge.call(
            "pipe2", "git://github.com/test-org/repo2.git", "PRIVATE"
          )
        ],
        "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
      }}}

      response1 = mock_graphql_client_response(data: page1_data)
      response2 = mock_graphql_client_response(data: page2_data)

      vars_page1 = { orgSlug: organization_slug, first: 50, after: nil }
      vars_page2 = { orgSlug: organization_slug, first: 50, after: "cursor1" }

      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(
          OssStats::BuildkiteClient::AllPipelinesQuery,
          variables: vars_page1,
          context: { token: token }
        ).and_return(response1)
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(
          OssStats::BuildkiteClient::AllPipelinesQuery,
          variables: vars_page2,
          context: { token: token }
        ).and_return(response2)

      expected_result = {
        "git://github.com/test-org/repo1" => [
          { slug: "#{organization_slug}/pipe1", visibility: "PUBLIC" }
        ],
        "git://github.com/test-org/repo2" => [
          { slug: "#{organization_slug}/pipe2", visibility: "PRIVATE" }
        ]
      }
      expect(bk_client.all_pipelines).to eq(expected_result)
    end

    it 'returns empty hash on GraphQL error' do
      response = mock_graphql_client_response(errors: ["Failed to fetch"])
      vars = { orgSlug: organization_slug, first: 50, after: nil }
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(
          OssStats::BuildkiteClient::AllPipelinesQuery,
          variables: vars,
          context: { token: token }
        ).and_return(response)

      error_log_msg = /GraphQL errors fetching all pipelines for #{organization_slug}: Failed to fetch/
      expect(OssStats::Log.instance).to receive(:error).with(error_log_msg)
      expect(bk_client.all_pipelines).to eq({})
    end
  end


  describe '#get_pipeline_builds' do
    let(:branch_name) { 'main' }
    let(:since_date) { Date.new(2023, 1, 1) }
    let(:iso_since_date) { since_date.to_datetime.rfc3339 }

    # Helper to create mock build edge
    def mock_build_edge(number, state, created_at, jobs_attrs)
      job_edges = jobs_attrs.map do |job_attr|
        { "node" => { "label" => job_attr[:label], "state" => job_attr[:state] } }
      end
      {
        "node" => {
          "number" => number,
          "state" => state,
          "createdAt" => created_at,
          "jobs" => { "edges" => job_edges }
        }
      }
    end

    context 'when API returns successful response with failed builds' do
      it 'returns an array of hashes with name and date for failed jobs' do
        builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
          "edges" => [
            mock_build_edge(1, 'PASSED', '2023-01-15T10:00:00Z',
                            [{ label: 'Passing Job', state: 'PASSED' }]),
            mock_build_edge(2, 'FAILED', '2023-01-16T11:00:00Z',
                            [{ label: 'Failed Job 1', state: 'FAILED' }]),
            mock_build_edge(3, 'FAILED', '2023-01-17T12:00:00Z', [
              { label: 'Successful Job on Failed Build', state: 'PASSED' },
              { label: 'Failed Job 2', state: 'FAILED' }
            ])
          ]
        }}}
        response = mock_graphql_client_response(data: builds_data)
        query_vars = {
          pipelineSlug: full_pipeline_slug, branch: [branch_name],
          createdFrom: iso_since_date, first: 50, after: nil
        }

        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(
            OssStats::BuildkiteClient::GetPipelineBuildsQuery,
            variables: query_vars,
            context: { token: token }
          ).and_return(response)

        expected_failures = [
          { name: 'Failed Job 1', date: '2023-01-16' },
          { name: 'Failed Job 2', date: '2023-01-17' }
        ]
        actual_builds = bk_client.get_pipeline_builds(
          pipeline_slug, branch_name, since_date
        )
        expect(actual_builds).to eq(expected_failures)
      end
    end

    context 'when API returns successful response with no failed builds' do
      it 'returns an empty array' do
        builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
          "edges" => [
            mock_build_edge(1, 'PASSED', '2023-01-15T10:00:00Z',
                            [{ label: 'Passing Job', state: 'PASSED' }])
          ]
        }}}
        response = mock_graphql_client_response(data: builds_data)
        query_vars = {
          pipelineSlug: full_pipeline_slug, branch: [branch_name],
          createdFrom: iso_since_date, first: 50, after: nil
        }
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(
            OssStats::BuildkiteClient::GetPipelineBuildsQuery,
            variables: query_vars,
            context: { token: token }
          ).and_return(response)
        actual_builds = bk_client.get_pipeline_builds(
          pipeline_slug, branch_name, since_date
        )
        expect(actual_builds).to be_empty
      end
    end

    context 'when handling pagination' do
      it 'combines data from all pages' do
        page1_builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => true, "endCursor" => 'cursor123' },
          "edges" => [
            mock_build_edge(1, 'FAILED', '2023-01-15T10:00:00Z',
                            [{ label: 'Failed Job Page 1', state: 'FAILED' }])
          ]
        }}}
        page2_builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
          "edges" => [
            mock_build_edge(2, 'FAILED', '2023-01-16T11:00:00Z',
                            [{ label: 'Failed Job Page 2', state: 'FAILED' }])
          ]
        }}}
        response1 = mock_graphql_client_response(data: page1_builds_data)
        response2 = mock_graphql_client_response(data: page2_builds_data)

        vars_page1 = {
          pipelineSlug: full_pipeline_slug, branch: [branch_name],
          createdFrom: iso_since_date, first: 50, after: nil
        }
        vars_page2 = {
          pipelineSlug: full_pipeline_slug, branch: [branch_name],
          createdFrom: iso_since_date, first: 50, after: 'cursor123'
        }

        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(
            OssStats::BuildkiteClient::GetPipelineBuildsQuery,
            variables: vars_page1, context: { token: token }
          ).and_return(response1)
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(
            OssStats::BuildkiteClient::GetPipelineBuildsQuery,
            variables: vars_page2, context: { token: token }
          ).and_return(response2)

        expected_failures = [
          { name: 'Failed Job Page 1', date: '2023-01-15' },
          { name: 'Failed Job Page 2', date: '2023-01-16' }
        ]
        actual_builds = bk_client.get_pipeline_builds(
          pipeline_slug, branch_name, since_date
        )
        expect(actual_builds).to eq(expected_failures)
      end
    end

    context 'when API returns an error' do
      it 'logs the error and returns an empty array' do
        response = mock_graphql_client_response(errors: ["Server error"])
        query_vars = {
          pipelineSlug: full_pipeline_slug, branch: [branch_name],
          createdFrom: iso_since_date, first: 50, after: nil
        }
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(
            OssStats::BuildkiteClient::GetPipelineBuildsQuery,
            variables: query_vars, context: { token: token }
          ).and_return(response)

        error_log_msg = /GraphQL errors for builds of #{full_pipeline_slug}, branch #{branch_name}: Server error/
        expect(OssStats::Log.instance).to receive(:error).with(error_log_msg)
        actual_builds = bk_client.get_pipeline_builds(
          pipeline_slug, branch_name, since_date
        )
        expect(actual_builds).to eq([])
      end
    end

    context 'when pipeline data is nil in response' do
      it 'logs a warning and returns an empty array' do
        response = mock_graphql_client_response(data: { "pipeline" => nil })
        query_vars = {
          pipelineSlug: full_pipeline_slug, branch: [branch_name],
          createdFrom: iso_since_date, first: 50, after: nil
        }

        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(
            OssStats::BuildkiteClient::GetPipelineBuildsQuery,
            variables: query_vars, context: { token: token }
          ).and_return(response)

        warn_log_msg = /No pipeline or builds data found for #{full_pipeline_slug}/
        expect(OssStats::Log.instance).to receive(:warn).with(warn_log_msg)
        actual_builds = bk_client.get_pipeline_builds(
          pipeline_slug, branch_name, since_date
        )
        expect(actual_builds).to eq([])
      end
    end
  end
end
