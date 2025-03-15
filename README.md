# chef-oss-stats

[![Lint](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml)
[![DCO Check](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml)

This repo aims to track stats that affect how Chef Users ("the community") can
interact with Progress' development teams and repositories.

Stats from this repo will (hopefully) be published in the weekly slack meetings.

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

You can create your own configuration file and use it with the `--config` option:

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

## Slack Meeting Stats

These are stats from the Slack meetings:

![Attendance](images/attendance-small.png) ![Build Status
Reports](images/build_status-small.png)

A per-meeting table can be found in [Slack Status
Tracking](team_slack_reports.md). This data is tracked in a sqlite database in
this repo which you can interact with via
[slack_meeting_stats.rb](src/slack_meeting_stats.rb). See the help message for
details.

To update the `team_slack_reports.md`, run run `slack_meeting_stats.rb --mode
markdown`.

To update the stats for the week run `slack_meeting_stats.rb --mode record`.

## Manual or semi-manual stats

There are a variety fo miscelanious manual statistics which are gathered
manually and recorded in [Misc stats](manual_stats/misc.md)
