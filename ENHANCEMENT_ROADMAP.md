# Chef OSS Stats Enhancement Roadmap

This document outlines a proposed series of enhancements to the chef-oss-stats
project. These improvements aim to gradually transform the project into a more
configurable and organization-agnostic metrics platform while respecting the
original functionality and maintaining backward compatibility.

## Proposed Enhancements

### PR #1: Configuration Foundation (Current)

**Goal**: Extract hardcoded defaults into YAML configuration files with backward
compatibility

**Proposed Changes**:

- Add YAML configuration file support
- Keep backward compatibility with existing functionality
- Add configuration schema validation
- Provide example configuration files
- Add documentation for configuration capabilities

**Benefits**:

- Makes project configurable without code changes
- Preserves all existing functionality
- Provides self-documenting configuration examples
- Improves maintainability

### PR #2: Config Loader Module and Logging

**Goal**: Create reusable configuration management and standardized logging

**Proposed Changes**:

- Extract configuration loading into a dedicated module
- Add standardized logging with appropriate levels
- Make logging configurable via the configuration files
- Add more robust error handling and validation
- Add progress indicators for long-running operations (e.g., CI processing)
  - Consider using gems like tty-spinner, tty-progressbar, or ruby-progressbar
  - Provide visual feedback during GitHub API requests and data processing

**Benefits**:

- Improves code organization and reusability
- Provides consistent error reporting
- Enables configurable log levels
- Makes debugging easier
- Enhances user experience with visual feedback during long-running tasks

### PR #3: Repository List Extraction

**Goal**: Move repository lists from bash script to configuration file

**Proposed Changes**:

- Update weekly report script to use configuration file
- Extract hardcoded repository lists to configuration
- Allow customizing repositories through configuration

**Benefits**:

- Eliminates hardcoded repository lists
- Makes it easier to add or modify repositories
- Reduces need to modify code for repo changes

### PR #4: Organization Parameterization

**Goal**: Fully parameterize organization-specific components

**Proposed Changes**:

- Extract team names and organization references
- Make all organization references configurable
- Support multiple organizations in reports

**Benefits**:

- Makes the tool usable for any GitHub organization
- Enables cross-organization reporting
- Increases project flexibility

### PR #5: Enhanced Documentation

**Goal**: Add comprehensive documentation for all features

**Proposed Changes**:

- Create dedicated documentation files
- Add examples for all configuration options
- Document advanced use cases
- Add developer documentation

**Benefits**:

- Makes the project more approachable
- Provides clear guidance for users
- Facilitates community contributions

## Long-Term Vision

In the future, the project could be enhanced with:

1. **Pluggable Data Sources**: Support for GitLab, BitBucket, and other Git
   hosting platforms
2. **Expanded Metrics**: More statistical analysis options
3. **Web Dashboard**: Optional web interface for visualizing metrics
4. **Reporting API**: Programmatic access to metrics data
5. **Integration Points**: Webhooks and other integration capabilities

These enhancements will be evaluated based on community interest and maintainer
feedback.
