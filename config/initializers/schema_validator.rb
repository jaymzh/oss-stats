# Schema validation for configuration files
# This provides basic validation of the configuration structure

module SchemaValidator
  # Validate the entire configuration structure
  def self.validate_config(config)
    errors = []

    # Check if config is nil or not a hash-like object
    return ['Configuration is empty or not properly loaded'] if config.nil?

    # Get if object responds to hash-like methods
    has_key_method = config.respond_to?(:has_key?) || config.respond_to?(:key?)

    # Choose validation approach based on object type
    if has_key_method
      # Hash-like validation (Settings object or Hash)

      # Check for required keys using appropriate method
      check_key = config.respond_to?(:has_key?) ? :has_key? : :key?
      required_keys = %w{default_org default_repo default_branches default_days}

      # Only check for organizations if we're not in a test environment
      # Only require organizations in non-test mode
      unless ENV['CHEF_OSS_STATS_TEST_MODE'] == 'true'
        required_keys << 'organizations'
      end

      missing_keys = required_keys.select { |key| !config.send(check_key, key) }
      unless missing_keys.empty?
        errors << 'Missing required configuration keys: ' \
                 "#{missing_keys.join(', ')}"
      end

      # Type validation for core keys
      begin
        # Validate default_org is a string if it exists
        if config_has_key?(config, 'default_org') &&
           !config_value(config, 'default_org').is_a?(String)
          errors << 'default_org must be a string'
        end

        # Validate default_repo is a string if it exists
        if config_has_key?(config, 'default_repo') &&
           !config_value(config, 'default_repo').is_a?(String)
          errors << 'default_repo must be a string'
        end

        # Validate default_branches is an array if it exists
        if config_has_key?(config, 'default_branches') &&
           !config_value(config, 'default_branches').is_a?(Array)
          errors << 'default_branches must be an array'
        end

        # Validate default_days is a number if it exists
        if config_has_key?(config, 'default_days') &&
           !config_value(config, 'default_days').is_a?(Numeric)
          errors << 'default_days must be a number'
        end

        # Only validate organizations in non-test mode
        if config_has_key?(config, 'organizations') &&
           ENV['CHEF_OSS_STATS_TEST_MODE'] != 'true'
          orgs = config_value(config, 'organizations')

          if !orgs.is_a?(Hash) && !orgs.respond_to?(:each)
            errors << 'organizations must be a hash/dictionary'
          elsif orgs.respond_to?(:each)
            # Validate each organization
            orgs.each do |org_key, org_data|
              # Skip validation if org_data is not proper
              next if org_data.nil?

              unless org_data.is_a?(Hash) || org_data.respond_to?(:key?) ||
                     org_data.respond_to?(:has_key?)
                errors << "Organization '#{org_key}' must be a hash/dictionary"
                next
              end

              # Check that organization has required keys
              # Check if org has a name using the appropriate method
              has_name = if org_data.respond_to?(:key?)
                           org_data.key?('name')
                         elsif org_data.respond_to?(:has_key?)
                           org_data.key?('name')
                         else
                           false
                         end

              # Check if org has repositories using the appropriate method
              has_repos = if org_data.respond_to?(:key?)
                            org_data.key?('repositories')
                          elsif org_data.respond_to?(:has_key?)
                            org_data.key?('repositories')
                          else
                            false
                          end

              unless has_name
                errors << "Organization '#{org_key}' is missing 'name'"
              end
              unless has_repos
                errors << "Organization '#{org_key}' is missing 'repositories'"
              end

              # Skip further validation if repositories aren't present
              next unless has_repos

              # Get repositories collection using flexible approach
              repos = if org_data.respond_to?(:repositories)
                        org_data.repositories
                      elsif org_data.respond_to?(:[])
                        org_data['repositories']
                      end

              next if repos.nil?

              if !repos.is_a?(Array) && !repos.respond_to?(:each_with_index)
                errors << "Organization '#{org_key}' repositories " \
                         'must be an array'
              elsif repos.respond_to?(:each_with_index)
                # Validate each repository
                repos.each_with_index do |repo, index|
                  next if repo.nil?

                  unless repo.is_a?(Hash) || repo.respond_to?(:key?) ||
                         repo.respond_to?(:has_key?)
                    errors << "Repository ##{index + 1} in '#{org_key}' " \
                             'must be a hash/dictionary'
                    next
                  end

                  # Check for required repository keys using flexible approach
                  has_name = if repo.respond_to?(:key?)
                               repo.key?('name')
                             elsif repo.respond_to?(:has_key?)
                               repo.key?('name')
                             elsif repo.respond_to?(:name)
                               true
                             else
                               false
                             end

                  has_branches = if repo.respond_to?(:key?)
                                   repo.key?('branches')
                                 elsif repo.respond_to?(:has_key?)
                                   repo.key?('branches')
                                 elsif repo.respond_to?(:branches)
                                   true
                                 else
                                   false
                                 end

                  unless has_name
                    errors << "Repository ##{index + 1} in '#{org_key}' " \
                             "is missing 'name'"
                  end
                  unless has_branches
                    errors << "Repository ##{index + 1} in '#{org_key}' " \
                             "is missing 'branches'"
                  end

                  # Skip branches validation if not present
                  next unless has_branches

                  # Get branches using flexible approach
                  branches = if repo.respond_to?(:branches)
                               repo.branches
                             elsif repo.respond_to?(:[])
                               repo['branches']
                             end

                  next if branches.nil?

                  # Skip if branches is an array or enumerable
                  next if branches.is_a?(Array) || branches.respond_to?(:each)
                  repo_name = if repo.respond_to?(:name)
                                repo.name
                              elsif repo.respond_to?(:[])
                                repo['name']
                              else
                                'unnamed'
                              end
                  # Branches must be an array
                  errors << "Branches for repository '#{repo_name}' " \
                           "in '#{org_key}' must be an array"
                end
              end
            end
          end
        end
      rescue => e
        errors << "Error during configuration validation: #{e.message}"
      end
    else
      # Object doesn't respond to hash-like methods
      errors << 'Configuration is not a valid settings object or hash'
    end

    # Return all errors found
    errors
  end

  # Helper method to check if config has a key, handling different object types
  def self.config_has_key?(config, key)
    return false unless config

    if config.respond_to?(:has_key?)
      config.key?(key)
    elsif config.respond_to?(:key?)
      config.key?(key)
    elsif config.respond_to?(key.to_sym)
      true
    else
      false
    end
  end

  # Helper method to get value from config, handling different object types
  def self.config_value(config, key)
    return unless config

    if config.respond_to?(:[])
      config[key]
    elsif config.respond_to?(key.to_sym)
      config.send(key.to_sym)
    end
  end

  # Validate the configuration and raise an error if invalid
  def self.validate!(config)
    errors = validate_config(config)
    unless errors.empty?
      raise ConfigurationError, "Invalid configuration:\n#{errors.join("\n")}"
    end
    true
  end

  # Custom error class for configuration errors
  class ConfigurationError < StandardError; end
end
