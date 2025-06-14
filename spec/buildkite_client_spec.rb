require 'oss_stats/buildkite_client'
require 'date'

RSpec.describe OssStats::BuildkiteClient do
  let(:token) { 'test-token' }
  let(:organization_slug) { 'test-org' }
  let(:client) { described_class.new(token, organization_slug) }

  describe '#get_pipeline_builds' do
    let(:pipeline_slug) { 'test-pipeline' }
    let(:pull_request_id) { '123' }
    let(:from_date) { Date.new(2024, 1, 1) }
    let(:to_date) { Date.new(2024, 1, 31) }

    context 'when the API returns builds' do
      let(:mock_api_response) do
        {
          'data' => {
            'pipeline' => {
              'builds' => {
                'edges' => [
                  {
                    'node' => {
                      'state' => 'PASSED',
                      'jobs' => {
                        'edges' => [
                          { 'node' => { 'label' => 'Test', 'state' => 'PASSED' } },
                          { 'node' => { 'label' => 'Lint', 'state' => 'PASSED' } }
                        ]
                      }
                    }
                  },
                  {
                    'node' => {
                      'state' => 'FAILED',
                      'jobs' => {
                        'edges' => [
                          { 'node' => { 'label' => 'Test', 'state' => 'FAILED' } },
                          { 'node' => { 'label' => 'Lint', 'state' => 'PASSED' } }
                        ]
                      }
                    }
                  }
                ],
                'pageInfo' => {
                  'hasNextPage' => false,
                  'endCursor' => nil
                }
              }
            }
          }
        }
      end

      before do
        # Mock the execute_graphql_query method
        allow(client).to receive(:execute_graphql_query).and_return(mock_api_response)
      end

      it 'returns a list of builds with their job statuses' do
        builds = client.get_pipeline_builds(pipeline_slug, pull_request_id, from_date, to_date)

        expect(builds.size).to eq(2)
        expect(builds[0]['node']['state']).to eq('PASSED')
        expect(builds[0]['node']['jobs']['edges'].size).to eq(2)
        expect(builds[0]['node']['jobs']['edges'][0]['node']['state']).to eq('PASSED')

        expect(builds[1]['node']['state']).to eq('FAILED')
        expect(builds[1]['node']['jobs']['edges'].size).to eq(2)
        expect(builds[1]['node']['jobs']['edges'][0]['node']['state']).to eq('FAILED')
      end
    end

    context 'when the API response is paginated' do
      let(:mock_api_response_page1) do
        {
          'data' => {
            'pipeline' => {
              'builds' => {
                'edges' => [
                  { 'node' => { 'state' => 'PASSED', 'jobs' => { 'edges' => [] } } }
                ],
                'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'cursor1' }
              }
            }
          }
        }
      end
      let(:mock_api_response_page2) do
        {
          'data' => {
            'pipeline' => {
              'builds' => {
                'edges' => [
                  { 'node' => { 'state' => 'FAILED', 'jobs' => { 'edges' => [] } } }
                ],
                'pageInfo' => { 'hasNextPage' => false, 'endCursor' => nil }
              }
            }
          }
        }
      end

      before do
        # Mock execute_graphql_query to return page 1 then page 2
        allow(client).to receive(:execute_graphql_query)
          .and_return(mock_api_response_page1, mock_api_response_page2)
      end

      it 'fetches all builds across pages' do
        builds = client.get_pipeline_builds(pipeline_slug, pull_request_id, from_date, to_date)
        expect(builds.size).to eq(2)
        expect(builds[0]['node']['state']).to eq('PASSED')
        expect(builds[1]['node']['state']).to eq('FAILED')
      end

      it 'makes two API calls' do
        expect(client).to receive(:execute_graphql_query).twice
        client.get_pipeline_builds(pipeline_slug, pull_request_id, from_date, to_date)
      end
    end

    context 'when the API call fails' do
      before do
        allow(client).to receive(:execute_graphql_query).and_raise(StandardError.new("API Error"))
        # Mock the logger to check if error is logged
        allow(client).to receive_message_chain(:log, :error)
      end

      it 'returns an empty array' do
        builds = client.get_pipeline_builds(pipeline_slug, pull_request_id, from_date, to_date)
        expect(builds).to be_empty
      end

      it 'logs the error' do
        expected_log_message = /Error in get_pipeline_builds for slug test-org\/test-pipeline: API Error/
        expect(client).to receive_message_chain(:log, :error).with(expected_log_message)
        client.get_pipeline_builds(pipeline_slug, pull_request_id, from_date, to_date)
      end
    end

    context 'when the API returns no builds' do
      let(:mock_api_response) do
        {
          'data' => {
            'pipeline' => {
              'builds' => {
                'edges' => [],
                'pageInfo' => {
                  'hasNextPage' => false,
                  'endCursor' => nil
                }
              }
            }
          }
        }
      end

      before do
        allow(client).to receive(:execute_graphql_query).and_return(mock_api_response)
      end

      it 'returns an empty array' do
        builds = client.get_pipeline_builds(pipeline_slug, pull_request_id, from_date, to_date)
        expect(builds).to be_empty
      end
    end
  end
end
