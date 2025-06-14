require 'spec_helper'
require 'oss_stats/buildkite_client'
require 'graphql/client' # Required for GraphQL::Client::Response, etc.

# Remove WebMock as we are no longer mocking HTTP for schema,
# and query calls will be mocked at the graphql-client instance level.
# require 'webmock/rspec'
# WebMock.disable_net_connect!(allow_localhost: true)

describe OssStats::BuildkiteClient do
  let(:token) { 'fake_buildkite_token' }
  let(:organization_slug) { 'test-org' }
  let(:pipeline_slug) { 'test-pipeline' }
  let(:full_pipeline_slug) { "#{organization_slug}/#{pipeline_slug}" }

  # This is the mock for the GraphQL::Client instance that will be
  # used by our BuildkiteClient instance.
  let(:mock_gql_client) { instance_double(GraphQL::Client) }
  let(:mock_schema) do
    # Create a minimal, valid schema double.
    # It needs to be robust enough for `GraphQL::Client.new(schema: @schema, ...)`
    # and for `@client.parse` to be called on it.
    # A simple double might not be enough if .parse relies on schema specifics.
    # For now, let's use a more generic instance_double.
    # If .parse fails, we might need a more sophisticated schema mock or load
    # a minimal valid schema from a string/fixture.
    instance_double(GraphQL::Schema, get_type: nil, "is_a?" => true)
  end
  let(:schema_path) { File.expand_path('schema.json', File.join(__dir__, '../../src/lib/oss_stats')) }


  # `bk_client` is the instance of our class under test.
  let(:bk_client) { described_class.new(token, organization_slug) }

  before do
    # Mock File.exist? to return true for the schema path
    allow(File).to receive(:exist?).with(schema_path).and_return(true)
    # Mock GraphQL::Client.load_schema to return our mock_schema
    allow(GraphQL::Client).to receive(:load_schema).with(schema_path).and_return(mock_schema)

    # Mock GraphQL::Client.new to return our mock_gql_client instance
    # This ensures our BuildkiteClient instance uses our mock GQL client.
    allow(GraphQL::Client).to receive(:new)
      .with(schema: mock_schema, execute: anything) # `execute` is the HTTP adapter
      .and_return(mock_gql_client)

    # Mock the .parse method on our mock_gql_client for each query.
    # The BuildkiteClient's private query definition methods will call this.
    # We need to return a distinguishable object for each query if tests
    # need to verify that the correct query definition is being used.
    # For now, just returning a generic double for parsed queries.
    allow(mock_gql_client).to receive(:parse).and_return(instance_double(GraphQL::Client::Definition, "name" => "ParsedQuery"))
  end


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

      # Now we expect `query` to be called on our mock_gql_client instance
      allow(mock_gql_client).to receive(:query)
        .with(anything, variables: expected_vars, context: { token: token }) # `anything` for parsed query
        .and_return(response)

      result = bk_client.get_pipeline(pipeline_slug)
      expect(result).to eq({ "visibility" => "PUBLIC" })
    end

    it 'returns nil when pipeline is not found' do
      response = mock_graphql_client_response(data: { "pipeline" => nil })
      expected_vars = { slug: full_pipeline_slug }
      allow(mock_gql_client).to receive(:query)
        .with(anything, variables: expected_vars, context: { token: token })
        .and_return(response)

      expect(bk_client.get_pipeline(pipeline_slug)).to be_nil
    end

    it 'returns nil and logs errors when GraphQL errors occur' do
      response = mock_graphql_client_response(errors: ["Server error"])
      expected_vars = { slug: full_pipeline_slug }
      allow(mock_gql_client).to receive(:query)
        .with(anything, variables: expected_vars, context: { token: token })
        .and_return(response)

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

      allow(mock_gql_client).to receive(:query)
        .with(anything, variables: vars_page1, context: { token: token })
        .and_return(response1)
      allow(mock_gql_client).to receive(:query)
        .with(anything, variables: vars_page2, context: { token: token })
        .and_return(response2)

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
      allow(mock_gql_client).to receive(:query)
        .with(anything, variables: vars, context: { token: token })
        .and_return(response)

      error_log_msg = /GraphQL errors fetching all pipelines for #{organization_slug}: Failed to fetch/
      expect(OssStats::Log.instance).to receive(:error).with(error_log_msg)
      expect(bk_client.all_pipelines).to eq({})
    end
  end


  describe '#get_pipeline_builds' do
    let(:branch_name) { 'main' }
    let(:since_date) { Date.new(2023, 1, 1) }
    let(:iso_since_date) { since_date.to_datetime.rfc3339 }

    def mock_build_edge(number, state, created_at, jobs_attrs)
      job_edges = jobs_attrs.map do |job_attr|
        { "node" => { "label" => job_attr[:label], "state" => job_attr[:state] } }
      end
      { "node" => { "number" => number, "state" => state, "createdAt" => created_at, "jobs" => { "edges" => job_edges } } }
    end

    context 'when API returns successful response with failed builds' do
      it 'returns an array of hashes with name and date for failed jobs' do
        builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
          "edges" => [
            mock_build_edge(1, 'PASSED', '2023-01-15T10:00:00Z', [{ label: 'Passing Job', state: 'PASSED' }]),
            mock_build_edge(2, 'FAILED', '2023-01-16T11:00:00Z', [{ label: 'Failed Job 1', state: 'FAILED' }]),
            mock_build_edge(3, 'FAILED', '2023-01-17T12:00:00Z', [
              { label: 'Successful Job on Failed Build', state: 'PASSED' },
              { label: 'Failed Job 2', state: 'FAILED' }
            ])
          ]
        }}}
        response = mock_graphql_client_response(data: builds_data)
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }

        allow(mock_gql_client).to receive(:query)
          .with(anything, variables: query_vars, context: { token: token })
          .and_return(response)

        expected_failures = [
          { name: 'Failed Job 1', date: '2023-01-16' },
          { name: 'Failed Job 2', date: '2023-01-17' }
        ]
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to eq(expected_failures)
      end
    end

    context 'when API returns successful response with no failed builds' do
      it 'returns an empty array' do
        builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
          "edges" => [mock_build_edge(1, 'PASSED', '2023-01-15T10:00:00Z', [{ label: 'Passing Job', state: 'PASSED' }])]
        }}}
        response = mock_graphql_client_response(data: builds_data)
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }
        allow(mock_gql_client).to receive(:query)
          .with(anything, variables: query_vars, context: { token: token })
          .and_return(response)
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to be_empty
      end
    end

    context 'when handling pagination' do
      it 'combines data from all pages' do
        page1_builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => true, "endCursor" => 'cursor123' },
          "edges" => [mock_build_edge(1, 'FAILED', '2023-01-15T10:00:00Z', [{ label: 'Failed Job Page 1', state: 'FAILED' }])]
        }}}
        page2_builds_data = { "pipeline" => { "builds" => {
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
          "edges" => [mock_build_edge(2, 'FAILED', '2023-01-16T11:00:00Z', [{ label: 'Failed Job Page 2', state: 'FAILED' }])]
        }}}
        response1 = mock_graphql_client_response(data: page1_builds_data)
        response2 = mock_graphql_client_response(data: page2_builds_data)

        vars_page1 = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }
        vars_page2 = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: 'cursor123' }

        allow(mock_gql_client).to receive(:query)
          .with(anything, variables: vars_page1, context: { token: token })
          .and_return(response1)
        allow(mock_gql_client).to receive(:query)
          .with(anything, variables: vars_page2, context: { token: token })
          .and_return(response2)

        expected_failures = [
          { name: 'Failed Job Page 1', date: '2023-01-15' },
          { name: 'Failed Job Page 2', date: '2023-01-16' }
        ]
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to eq(expected_failures)
      end
    end

    context 'when API returns an error' do
      it 'logs the error and returns an empty array' do
        response = mock_graphql_client_response(errors: ["Server error"])
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }
        allow(mock_gql_client).to receive(:query)
          .with(anything, variables: query_vars, context: { token: token })
          .and_return(response)

        error_log_msg = /GraphQL errors for builds of #{full_pipeline_slug}, branch #{branch_name}: Server error/
        expect(OssStats::Log.instance).to receive(:error).with(error_log_msg)
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to eq([])
      end
    end

    context 'when pipeline data is nil in response' do
      it 'logs a warning and returns an empty array' do
        response = mock_graphql_client_response(data: { "pipeline" => nil })
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }

        allow(mock_gql_client).to receive(:query)
          .with(anything, variables: query_vars, context: { token: token })
          .and_return(response)

        warn_log_msg = /No pipeline or builds data found for #{full_pipeline_slug}/
        expect(OssStats::Log.instance).to receive(:warn).with(warn_log_msg)
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to eq([])
      end
    end
  end
end
