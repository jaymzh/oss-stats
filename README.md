# chef-oss-stats

[![Lint](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml)
[![DCO Check](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml)

This repo aims to track stats that affect how Chef Users ("the community") can
interact with Progress' development teams and repositories.

Stats from this repo will (hopefully) be published in the weekly slack meetings.

## Installation

### Prerequisites

- Ruby 2.7 or newer
- Bundler gem
- GitHub API access (token) for repository data

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/jaymzh/chef-oss-stats.git
   cd chef-oss-stats
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Configure GitHub access:
   - Create a GitHub Personal Access Token with `repo` scope
   - Set it as an environment variable: `export GITHUB_TOKEN=your_token_here`
   - Alternatively, authenticate with GitHub CLI (`gh auth login`)

4. Create or modify a configuration file (see [Configuration](#configuration) section)
   - Use the examples in `examples/` directory as a starting point
   - Copy and modify `examples/basic_config.yml` for a simple setup

## Configuration

The chef-oss-stats tools can be configured through YAML configuration files.
By default, the system uses the configuration in `config/settings.yml`, but you can
provide custom configuration files using the `--config` option.

### Testing Configuration

The project includes tests for the configuration system. You can run these tests using:

```shell
# Run all tests
bundle exec rake test

# Run only configuration tests
bundle exec rake test_config
```

### Configuration Validation

The configuration files are automatically validated against a schema when loaded. If there are configuration errors, they will be reported with specific error messages. You can control validation behavior with environment variables:

- `CHEF_OSS_STATS_STRICT_CONFIG=true` - Exit with error code if configuration is invalid
- `CHEF_OSS_STATS_IGNORE_CONFIG_ERRORS=true` - Continue despite configuration validation errors

The validation ensures:
- Required configuration keys are present
- Values have the correct data types
- Organization structure is properly defined
- Repository references are valid

#### Validating Your Configuration

To validate your configuration without running the full application, use the included validation script:

```shell
# Validate a configuration file
ruby examples/validate_config.rb path/to/your/config.yml
```

This tool will check your configuration file for syntax and schema errors before you use it with the main application.

### Configuration Schema

The configuration uses the following schema:

```yaml
# Default values used when not provided via CLI arguments
default_org: "your-org"         # Default GitHub organization
default_repo: "your-repo"       # Default repository name
default_branches:               # Default branches to analyze
  - "main"
default_days: 30                # Default number of days to look back
default_mode: "all"             # Default mode (ci, pr, issue, or all)
ci_timeout: 180                 # Timeout for CI processing in seconds (default: 180)

# Organization configuration section
organizations:
  your-org:                     # Organization key (should match default_org for default behavior)
    name: "Your Organization"   # Human-readable organization name
    repositories:               # List of repositories to analyze
      - name: "repo1"           # Repository name
        branches: ["main"]      # Branches to analyze for this repository
      - name: "repo2"
        branches: ["main", "develop"]
```

### Custom Configuration File

You can create your own configuration file and use it with the `--config` option. Several example configuration files are provided in the `examples/` directory:

- `examples/minimal_config.yml` - Minimal configuration with basic settings
- `examples/basic_config.yml` - Standard single-organization configuration
- `examples/multi_org_config.yml` - Advanced multi-organization setup

Here's a basic example:

```yaml
# custom_config.yml
default_org: "your-org"
default_repo: "your-repo"
default_branches: 
  - "main"
default_days: 30
default_mode: "all"

# Organization configuration section
organizations:
  your-org:
    name: "Your Organization"
    repositories:
      - name: "repo1"
        branches: ["main"]
      - name: "repo2"
        branches: ["main", "develop"]
```

To use a custom configuration:

```shell
$ ./src/chef_ci_status.rb --config path/to/your/config.yml
```

You can also copy and modify the examples as a starting point for your own configuration.

## Development

### Testing

The project uses [Minitest](https://github.com/seattlerb/minitest) for testing. Tests are organized in the `spec/` directory.

To run the tests:

```shell
# Install dependencies
bundle install

# Run all tests
bundle exec rake test

# Run only configuration tests
bundle exec rake test_config
```

### Linting

Code quality is maintained using Cookstyle (RuboCop):

```shell
# Run linting
bundle exec cookstyle
```

## Using the Tool

### Command Options

The script supports several command-line options:

```
--config CONFIG_FILE      Path to custom configuration file
--org ORG                 GitHub organization name
--repo REPO               GitHub repository name
--branches BRANCHES       Comma-separated list of branches
--days DAYS               Number of days to analyze
--mode MODE               Comma-separated list of modes: ci,pr,issue,all
--ci-timeout SECONDS      Timeout for CI processing in seconds
--skip-ci                 Skip CI status processing (faster)
--dry-run                 Skip all GitHub API calls (for testing)
-v, --verbose             Enable verbose output
```

### Authentication

The script requires a GitHub token for authentication. It will be obtained in the following order:
1. From the `GITHUB_TOKEN` environment variable
2. From the GitHub CLI configuration
3. By running `gh auth token` if GitHub CLI is available

Example:
```bash
# Using environment variable
GITHUB_TOKEN=your_token ./src/chef_ci_status.rb --config config/my_config.yml

# Using GitHub CLI (if authenticated)
./src/chef_ci_status.rb --config config/my_config.yml
```

### Common Usage Examples

Here are some common usage examples for the tool:

#### Analyzing a Specific Repository

To analyze a specific repository with default settings:

```bash
# Analyze chef/chef repository for the last 30 days
./src/chef_ci_status.rb --org chef --repo chef
```

#### Customizing Time Range

To analyze a different time period:

```bash
# Analyze chef/chef repository for the last 7 days
./src/chef_ci_status.rb --org chef --repo chef --days 7

# Analyze chef/chef repository for the last 90 days
./src/chef_ci_status.rb --org chef --repo chef --days 90
```

#### Analyzing Multiple Branches

To analyze multiple branches in a repository:

```bash
# Analyze main and develop branches
./src/chef_ci_status.rb --org chef --repo chef --branches main,develop
```

#### Focusing on Specific Metrics

To focus on particular metrics types:

```bash
# Only analyze PR stats
./src/chef_ci_status.rb --org chef --repo chef --mode pr

# Only analyze CI stats
./src/chef_ci_status.rb --org chef --repo chef --mode ci

# Analyze PR and Issue stats, but skip CI (faster)
./src/chef_ci_status.rb --org chef --repo chef --mode pr,issue

# Alternatively, use the --skip-ci flag
./src/chef_ci_status.rb --org chef --repo chef --skip-ci
```

#### Using Custom Configuration

To use a custom configuration file:

```bash
# Use a custom configuration file
./src/chef_ci_status.rb --config examples/basic_config.yml

# Override values from config file
./src/chef_ci_status.rb --config examples/basic_config.yml --days 14 --branches main
```

#### Testing Without API Calls

For testing or validating without making GitHub API calls:

```bash
# Dry run - no actual API calls will be made
./src/chef_ci_status.rb --config examples/basic_config.yml --dry-run
```

#### Advanced Usage

For CI performance tuning:

```bash
# Set a custom timeout for CI processing (in seconds)
./src/chef_ci_status.rb --org chef --repo chef --ci-timeout 300

# Get verbose output for debugging
./src/chef_ci_status.rb --org chef --repo chef --verbose
```

## Build Status

The [chef_ci_status.rb](src/chef_ci_status.rb) script will walk GitHub CI
workflows for a given repo, and report the number of days each one was red on
the `main` branch in the last N days (default: 30).

The output looks like:

```shell
$ ./src/chef_ci_status.rb --days 1 --branches chef-18,main
*[chef/chef] Stats (Last 1 days)*

  PR Stats (Last 1 days):
    Opened PRs: 11
    Closed PRs: 12
    Oldest Open PR: 2024-09-06 (188 days open, last activity 49 days ago)
    Stale PRs (>30 days without comment): 11
    Avg Time to Close PRs: 1.26 days

  Issue Stats (Last 1 days):
    Opened Issues: 0
    Closed Issues: 0
    Oldest Open Issue: 2024-09-23 (171 days open, last activity 27 days ago)
    Stale Issues (>30 days without comment): 13
    Avg Time to Close Issues: 0 hours

  CI Failure Stats (last 1 days):
    Branch: chef-18
      vm_lnx_x86_64 (almalinux-8): 1 days
      vm_lnx_x86_64 (rockylinux-9): 1 days
      unit: 1 days
      docr_lnx_x86_64 (rockylinux-8): 1 days

    Branch: main
      docr_lnx_x86_64 (debian-12): 1 days
      vm_lnx_x86_64 (oracle-8): 1 days
```

The wrapper [run_weekly_ci_reports.sh](src/run_weekly_ci_reports.sh) loops
over all the relevant repos and runs `chef-ci-status.rb`. This is intended
for posting in the weekly Chef Community Slack meeting.

To run the weekly reports:

```bash
# Generate weekly reports for all configured repositories
./src/run_weekly_ci_reports.sh

# Generate reports with a specific configuration file
CHEF_OSS_STATS_CONFIG=/path/to/config.yml ./src/run_weekly_ci_reports.sh
```

The script will process all repositories defined in the configuration file and output
formatted results suitable for sharing in meetings or reports.

## Slack Meeting Stats

These are stats from the Slack meetings:

![Attendance](images/attendance-small.png) ![Build Status
Reports](images/build_status-small.png)

A per-meeting table can be found in [Slack Status
Tracking](team_slack_reports.md). This data is tracked in a SQLite database in
this repo which you can interact with via
[slack_meeting_stats.rb](src/slack_meeting_stats.rb).

### Using the Slack Stats Tool

The slack_meeting_stats.rb script provides several modes for managing Slack meeting statistics:

```bash
# View help and available options
ruby src/slack_meeting_stats.rb --help

# Record stats for the current week
ruby src/slack_meeting_stats.rb --mode record

# Generate markdown report
ruby src/slack_meeting_stats.rb --mode markdown

# Export data to CSV
ruby src/slack_meeting_stats.rb --mode export --output-file stats.csv

# Generate graphs for visualization
ruby src/slack_meeting_stats.rb --mode graph
```

#### Recording Weekly Stats

To record stats for a meeting:

```bash
# Interactive mode to record stats for the current week
ruby src/slack_meeting_stats.rb --mode record

# Record stats with specific values
ruby src/slack_meeting_stats.rb --mode record --attendance 42 --build-status yes
```

#### Generating Reports

To generate reports for inclusion in documentation, Slack posts, or other communications:

```bash
# Update the team_slack_reports.md file with latest stats
ruby src/slack_meeting_stats.rb --mode markdown

# Display stats for the last 10 weeks
ruby src/slack_meeting_stats.rb --mode stats --weeks 10
```

## Manual or Semi-Manual Stats

There are a variety of miscellaneous manual statistics which are gathered
manually and recorded in [Misc stats](manual_stats/misc.md).

## Future Enhancements

See the [Enhancement Roadmap](ENHANCEMENT_ROADMAP.md) for details on planned improvements to this project.

## Contributing

Contributions to chef-oss-stats are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on the contribution process.

All contributions must include a Developer Certificate of Origin (DCO) sign-off. This can be done by adding `-s` to your git commit command:

```bash
git commit -s -m "Your detailed commit message"
```
