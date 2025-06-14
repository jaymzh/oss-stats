require 'net/http'
require 'json'
require 'uri'
require 'fileutils' # For FileUtils.mkdir_p

introspection_query = <<GRAPHQL
  query IntrospectionQuery {
    __schema {
      queryType { name }
      mutationType { name }
      subscriptionType { name }
      types {
        ...FullType
      }
      directives {
        name
        description
        locations
        args {
          ...InputValue
        }
      }
    }
  }

  fragment FullType on __Type {
    kind
    name
    description
    fields(includeDeprecated: true) {
      name
      description
      args {
        ...InputValue
      }
      type {
        ...TypeRef
      }
      isDeprecated
      deprecationReason
    }
    inputFields {
      ...InputValue
    }
    interfaces {
      ...TypeRef
    }
    enumValues(includeDeprecated: true) {
      name
      description
      isDeprecated
      deprecationReason
    }
    possibleTypes {
      ...TypeRef
    }
  }

  fragment InputValue on __InputValue {
    name
    description
    type { ...TypeRef }
    defaultValue
  }

  fragment TypeRef on __Type {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
                ofType {
                  kind
                  name
                }
              }
            }
          }
        }
      }
    }
  }
GRAPHQL

def fetch_and_save_schema
  uri = URI('https://graphql.buildkite.com/v1')
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri.request_uri)
  request['Content-Type'] = 'application/json'
  # NOTE: An Authorization header is typically required for Buildkite's GraphQL API.
  # This script will likely fail without a valid token.
  # request['Authorization'] = "Bearer YOUR_BUILDKITE_TOKEN"
  request.body = { query: introspection_query }.to_json

  begin
    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      parsed_response = JSON.parse(response.body)
      if parsed_response['data']
        # Corrected schema_dir path to be relative to the script's execution directory
        # Assuming the script is run from the repo root.
        schema_dir = File.join('src', 'lib', 'oss_stats')
        FileUtils.mkdir_p(schema_dir)
        schema_path = File.join(schema_dir, 'schema.json')

        File.open(schema_path, 'w') do |file|
          # Pretty print the JSON for readability
          file.write(JSON.pretty_generate(parsed_response))
        end
        puts "SUCCESS: Buildkite GraphQL schema saved to #{schema_path}"
        # Attempt to load it with GraphQL::Client to verify basic structure
        # This is an optional step for this script but good for validation
        begin
          # This require might fail if graphql-client gem is not installed in the env
          require 'graphql/client'
          GraphQL::Client.load_schema(schema_path)
          puts "SUCCESS: Schema at #{schema_path} was successfully loaded by graphql-client."
        rescue LoadError
          puts "WARNING: Could not require 'graphql/client'. Gem might not be installed."
          puts "         Schema saved to #{schema_path}, but cannot perform graphql-client validation."
        rescue StandardError => e
          puts "WARNING: Schema saved to #{schema_path}, but failed to validate with graphql-client: #{e.message}"
          puts "         The file might be valid but check its content or graphql-client setup."
        end

      elsif parsed_response['errors']
        puts "FAILURE: GraphQL API returned errors: #{parsed_response['errors']}"
        puts "         This might be due to missing authentication or other API issues."
      else
        puts "FAILURE: Response was successful, but no 'data' or 'errors' key found in JSON."
        puts "         Raw response body: #{response.body}"
      end
    else
      puts "FAILURE: HTTP request failed with status #{response.code} #{response.message}."
      puts "         Response body: #{response.body}"
      puts "         This is likely due to a missing or invalid Authorization token."
    end
  rescue StandardError => e
    puts "FAILURE: An error occurred during the request: #{e.message}"
    puts e.backtrace.join("\n")
  end
end

fetch_and_save_schema
