require 'spec_helper'
require 'oss_stats/buildkite_client'
require 'graphql/client' # Required for GraphQL::Client::Response, etc.

# Mock the schema loading to prevent network requests during class definition
# This needs to be done before `describe OssStats::BuildkiteClient` is parsed
# if Schema is a class constant loaded at class definition time.
# We create a basic double that can respond to `get_type` as that's often
# what the client might do internally during initialization or parsing.
# The specifics of this mock might need adjustment if the client's internal
# usage of the schema is more complex during parsing.
#
# A more robust way would be to load a fixture schema.json:
#   schema_fixture = File.read(File.join(__dir__, 'fixtures', 'buildkite_schema.json'))
#   FakeSchema = GraphQL::Client.load_schema(JSON.parse(schema_fixture))
#   stub_const("OssStats::BuildkiteClient::Schema", FakeSchema)
# For now, a simple double:
if defined?(OssStats::BuildkiteClient)
  # If the client class and its Schema constant are already loaded,
  # we might need to redefine the constant or ensure this runs before it's loaded.
  # This approach is a bit tricky due to load order.
  # A safer way is to ensure this code runs *before* `require 'oss_stats/buildkite_client'`.
  # However, spec_helper usually requires the code first.
  # For now, let's assume we can stub it if it's looked up dynamically or
  # if this runs early enough.
  # A common pattern is to put such stubs in spec_helper.rb.
  #
  # Given the current setup, we will stub GraphQL::Client.load_schema itself,
  # which is called during the definition of OssStats::BuildkiteClient::Schema.
  # This needs to happen *before* the class is fully loaded by the `require` statement.
  # This is tricky. A better way is to ensure the class can be initialized
  # with a schema, or to put this stubbing in a place that executes before
  # the class is defined (e.g. modify spec_helper or the require order).
  #
  # Let's try a direct stubbing of the constant if it's already defined,
  # or stub the method if we can catch it before `load_schema` is called.
  # This is more of a workaround for the current structure.
  #
  # The most reliable way for this specific structure is to allow the actual
  # load_schema to be called in tests but mock the HTTP call it makes.
  # However, the goal is to use graphql-client mocks.
  #
  # Let's assume `GraphQL::Client.load_schema` will be called when the class loads.
  # We need to control what it returns.
  # This should ideally be in `spec_helper.rb` or a similar global setup file.
  #
  # For the purpose of this script, we will assume that if we require `graphql/client`
  # first, we can then stub its methods before `oss_stats/buildkite_client` is required
  # and tries to use them. This usually works if the constants are defined dynamically
  # or if the require order can be managed.
  #
  # The provided solution structure has `require 'oss_stats/buildkite_client'`
  # at the top. So, `OssStats::BuildkiteClient::Schema` is likely already defined.
  # We will proceed by mocking `Client.query` directly.
  # The schema loading part is tricky to mock *after* the class is loaded
  # if it happens at class definition time.
  # For now, we'll focus on mocking the `query` method.
  # If schema loading makes a real HTTP call that WebMock was catching,
  # and WebMock is removed, tests might fail during setup.
  # The `graphql-client` might not make an HTTP call for `load_schema` if
  # the argument is already a schema object (e.g. from a JSON file).
  # If it's loading from an HTTP adapter, it would.
  # The refactored code uses `GraphQL::Client.load_schema(HTTPAdapter)`.
  # This WILL make an HTTP request.
  #
  # The best way to handle this is to allow that initial schema load HTTP request
  # in WebMock if we can't easily stub `GraphQL::Client.load_schema` before class load.
  # OR, modify the class to allow injecting the schema.
  #
  # Let's try to stub `GraphQL::Client.load_schema` before the describe block.
  # This is a bit of a hack due to load orders.
  # A cleaner solution would be to manage schema loading explicitly in the application.
  #
  # **Revisiting Schema Mocking Strategy:**
  # The most robust way to handle schema for tests when using `graphql-client` is
  # to have a `schema.json` file. Then load it using:
  # `MyGraphQLClient::Schema = GraphQL::Client.load_schema("path/to/schema.json")`
  # This avoids HTTP calls during class loading.
  # Since we don't have that, and `GraphQL::Client.load_schema(HTTPAdapter)` will
  # make an HTTP call, we MUST allow this call via WebMock OR globally stub
  # `GraphQL::Client.load_schema` to return a valid, minimal schema double.
  #
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
    # This is just to make GraphQL::Client.load_schema(HTTPAdapter) not fail.
    if request.body.include?("IntrospectionQuery")
      return {
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: { data: { __schema: { queryType: { name: "Query" }, types: [] } } }.to_json
      }
    end
    # For other queries, it should be mocked specifically by tests later.
    # Returning a generic error or an empty success to avoid test pollution.
    return { status: 418, body: {errors: [{message: "Unhandled GraphQL request in schema loading mock"}]}.to_json }
  })

end


describe OssStats::BuildkiteClient do
  let(:token) { 'fake_buildkite_token' }
  let(:organization_slug) { 'test-org' }
  let(:pipeline_slug) { 'test-pipeline' } # This is the short pipeline slug, not org/pipeline
  let(:full_pipeline_slug) { "#{organization_slug}/#{pipeline_slug}" } # Used in queries
  let(:bk_client) { described_class.new(token, organization_slug) } # Renamed to avoid conflict with GraphQL::Client

  # Helper to create a GraphQL::Client::Response
  def mock_graphql_client_response(data: nil, errors: nil)
    # Construct mock errors if any messages are provided
    mock_errors_obj = nil
    if errors && errors.any?
      # Assuming errors is an array of message strings
      # The actual error objects can be more complex
      error_hashes = errors.map { |msg| { "message" => msg } }
      mock_errors_obj = GraphQL::Client::Errors.new(data: nil, original_hash: {"errors" => error_hashes }, messages: error_hashes.map{|h| h["message"]})
    end
    GraphQL::Client::Response.new(data: data&.deep_stringify_keys, errors: mock_errors_obj, extensions: nil)
  end


  describe '#get_pipeline' do
    it 'returns pipeline visibility when successful' do
      mock_data = { "pipeline" => { "visibility" => "PUBLIC" } }
      response = mock_graphql_client_response(data: mock_data)
      expected_vars = { slug: full_pipeline_slug }

      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(OssStats::BuildkiteClient::GetPipelineQuery, variables: expected_vars, context: { token: token })
        .and_return(response)

      result = bk_client.get_pipeline(pipeline_slug)
      expect(result).to eq({ "visibility" => "PUBLIC" })
    end

    it 'returns nil when pipeline is not found' do
      response = mock_graphql_client_response(data: { "pipeline" => nil }) # Simulate not found
      expected_vars = { slug: full_pipeline_slug }
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(OssStats::BuildkiteClient::GetPipelineQuery, variables: expected_vars, context: { token: token })
        .and_return(response)

      expect(bk_client.get_pipeline(pipeline_slug)).to be_nil
    end

    it 'returns nil and logs errors when GraphQL errors occur' do
      response = mock_graphql_client_response(errors: ["Server error"])
      expected_vars = { slug: full_pipeline_slug }
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(OssStats::BuildkiteClient::GetPipelineQuery, variables: expected_vars, context: { token: token })
        .and_return(response)

      expect(OssStats::Log.instance).to receive(:error).with(/GraphQL errors for pipeline #{full_pipeline_slug}: Server error/)
      expect(bk_client.get_pipeline(pipeline_slug)).to be_nil
    end
  end

  describe '#all_pipelines' do
    let(:mock_pipeline_edge) { |slug, repo_url, visibility|
      { "node" => { "slug" => "#{organization_slug}/#{slug}", "repository" => { "url" => repo_url }, "visibility" => visibility } }
    }

    it 'fetches all pipelines with pagination' do
      page1_data = {
        "organization" => {
          "pipelines" => {
            "edges" => [mock_pipeline_edge.call("pipe1", "git://github.com/test-org/repo1.git", "PUBLIC")],
            "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor1" }
          }
        }
      }
      page2_data = {
        "organization" => {
          "pipelines" => {
            "edges" => [mock_pipeline_edge.call("pipe2", "git://github.com/test-org/repo2.git", "PRIVATE")],
            "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
          }
        }
      }

      response1 = mock_graphql_client_response(data: page1_data)
      response2 = mock_graphql_client_response(data: page2_data)

      vars_page1 = { orgSlug: organization_slug, first: 50, after: nil }
      vars_page2 = { orgSlug: organization_slug, first: 50, after: "cursor1" }

      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(OssStats::BuildkiteClient::AllPipelinesQuery, variables: vars_page1, context: { token: token })
        .and_return(response1)
      allow(OssStats::BuildkiteClient::Client).to receive(:query)
        .with(OssStats::BuildkiteClient::AllPipelinesQuery, variables: vars_page2, context: { token: token })
        .and_return(response2)

      expected_result = {
        "git://github.com/test-org/repo1" => [{ slug: "#{organization_slug}/pipe1", visibility: "PUBLIC" }],
        "git://github.com/test-org/repo2" => [{ slug: "#{organization_slug}/pipe2", visibility: "PRIVATE" }]
      }
      expect(bk_client.all_pipelines).to eq(expected_result)
    end

    it 'returns empty hash on GraphQL error' do
        response = mock_graphql_client_response(errors: ["Failed to fetch"])
        vars = { orgSlug: organization_slug, first: 50, after: nil }
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
            .with(OssStats::BuildkiteClient::AllPipelinesQuery, variables: vars, context: { token: token })
            .and_return(response)

        expect(OssStats::Log.instance).to receive(:error).with(/GraphQL errors fetching all pipelines for #{organization_slug}: Failed to fetch/)
        expect(bk_client.all_pipelines).to eq({})
    end
  end


  describe '#get_pipeline_builds' do
    let(:branch_name) { 'main' }
    let(:since_date) { Date.new(2023, 1, 1) }
    let(:iso_since_date) { since_date.to_datetime.rfc3339 }

    # Helper to create mock build edge
    def mock_build_edge(number, state, created_at, jobs)
      job_edges = jobs.map { |job| { "node" => { "label" => job[:label], "state" => job[:state] } } }
      { "node" => { "number" => number, "state" => state, "createdAt" => created_at, "jobs" => { "edges" => job_edges } } }
    end

    context 'when API returns successful response with failed builds' do
      it 'returns an array of hashes with name and date for failed jobs' do
        builds_data = {
          "pipeline" => {
            "builds" => {
              "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
              "edges" => [
                mock_build_edge(1, 'PASSED', '2023-01-15T10:00:00Z', [{ label: 'Passing Job', state: 'PASSED' }]),
                mock_build_edge(2, 'FAILED', '2023-01-16T11:00:00Z', [{ label: 'Failed Job 1', state: 'FAILED' }]),
                mock_build_edge(3, 'FAILED', '2023-01-17T12:00:00Z', [
                  { label: 'Successful Job on Failed Build', state: 'PASSED' },
                  { label: 'Failed Job 2', state: 'FAILED' }
                ])
              ]
            }
          }
        }
        response = mock_graphql_client_response(data: builds_data)
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }

        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(OssStats::BuildkiteClient::GetPipelineBuildsQuery, variables: query_vars, context: { token: token })
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
         builds_data = {
          "pipeline" => {
            "builds" => {
              "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
              "edges" => [
                mock_build_edge(1, 'PASSED', '2023-01-15T10:00:00Z', [{ label: 'Passing Job', state: 'PASSED' }])
              ]
            }
          }
        }
        response = mock_graphql_client_response(data: builds_data)
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(OssStats::BuildkiteClient::GetPipelineBuildsQuery, variables: query_vars, context: { token: token })
          .and_return(response)
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to be_empty
      end
    end

    context 'when handling pagination' do
      it 'combines data from all pages' do
        page1_builds_data = {
          "pipeline" => { "builds" => {
            "pageInfo" => { "hasNextPage" => true, "endCursor" => 'cursor123' },
            "edges" => [mock_build_edge(1, 'FAILED', '2023-01-15T10:00:00Z', [{ label: 'Failed Job Page 1', state: 'FAILED' }])]
          }}
        }
        page2_builds_data = {
          "pipeline" => { "builds" => {
            "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
            "edges" => [mock_build_edge(2, 'FAILED', '2023-01-16T11:00:00Z', [{ label: 'Failed Job Page 2', state: 'FAILED' }])]
          }}
        }
        response1 = mock_graphql_client_response(data: page1_builds_data)
        response2 = mock_graphql_client_response(data: page2_builds_data)

        vars_page1 = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }
        vars_page2 = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: 'cursor123' }

        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(OssStats::BuildkiteClient::GetPipelineBuildsQuery, variables: vars_page1, context: { token: token })
          .and_return(response1)
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(OssStats::BuildkiteClient::GetPipelineBuildsQuery, variables: vars_page2, context: { token: token })
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
        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(OssStats::BuildkiteClient::GetPipelineBuildsQuery, variables: query_vars, context: { token: token })
          .and_return(response)

        expect(OssStats::Log.instance).to receive(:error).with(/GraphQL errors for builds of #{full_pipeline_slug}, branch #{branch_name}: Server error/)
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to eq([])
      end
    end

    context 'when pipeline data is nil in response (e.g. pipeline not found by slug)' do
      it 'logs a warning and returns an empty array' do
        # This simulates a case where the top-level query for pipeline returns nil for the pipeline object
        response = mock_graphql_client_response(data: { "pipeline" => nil })
        query_vars = { pipelineSlug: full_pipeline_slug, branch: [branch_name], createdFrom: iso_since_date, first: 50, after: nil }

        allow(OssStats::BuildkiteClient::Client).to receive(:query)
          .with(OssStats::BuildkiteClient::GetPipelineBuildsQuery, variables: query_vars, context: { token: token })
          .and_return(response)

        # The warning comes from the client method itself when it finds no data for pipeline.builds
        expect(OssStats::Log.instance).to receive(:warn).with(/No pipeline or builds data found for #{full_pipeline_slug}/)
        expect(bk_client.get_pipeline_builds(pipeline_slug, branch_name, since_date)).to eq([])
      end
    end

    # Test for variable correctness is implicitly covered by `with` matchers on `Client.query`.
    # No separate test like the old 'filtering by branch and date' with WebMock body inspection is needed
    # as RSpec's mock verification handles this.
  end
end
