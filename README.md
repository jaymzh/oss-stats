# OSS Stats

[![Lint](https://github.com/jaymzh/oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/lint.yml)
[![DCO Check](https://github.com/jaymzh/oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/dco.yml)

This is a collection of scripts that aim to make it easier to track and report
various metrics around health of an open source project.

It was born out of the Chef ecosystem, but should be generic enough for any
project. The [chef-oss-stats](https://github.com/jaymzh/chef-oss-stats/) repo
is a useful example to look at to see the results, though.

## How to use this repo

You'll want to create your own repository to keep the data and results that
these scripts use and generate about your project.

This repo has a script that'll do all the required initial work. On your new
repo, do:

```shell
<path_to_this_repo>/scripts/intialize_repo.sh
```

This will:

* Generate basic config skeleton files for the various scripts
* Create necessary directories
* Setup a GitHub Actions workflow for you

You can run it with `-n` (dryrun) to see what it will do without actually
doing anything.

## CI Stats

The [ci_stats.rb](src/ci_stats.rb) script will walk GitHub CI workflows for a
given repo, and report the number of days each one was red on the `main` branch
in the last N days (default: 30) as well as gather stats on Issues and PRs.

The output looks like:

```shell
$ ./src/ci_stats.rb --days 7 --branches chef-18,main --org chef --repo chef
*_[chef/chef] Stats (Last 7 days)_*

* PR Stats:
    * Opened PRs: 15
    * Closed PRs: 13
    * Oldest Open PR: 2024-09-06 (208 days open, last activity 69 days ago)
    * Stale PR (>30 days without comment): 8
    * Avg Time to Close PRs: 18.47 days

* Issue Stats:
    * Opened Issues: 2
    * Closed Issues: 1
    * Oldest Open Issue: 2024-07-26 (250 days open, last activity 233 days ago)
    * Stale Issue (>30 days without comment): 14
    * Avg Time to Close Issues: 14.27 days

* CI Failure Stats:
    * Branch: main
        * docr_lnx_x86_64 (debian-11): 1 days
        * docr_lnx_x86_64 (rockylinux-8): 1 days
        * docr_lnx_x86_64 (ubuntu-2204): 1 days
        * vm_lnx_x86_64 (almalinux-8): 1 days
        * vm_lnx_x86_64 (almalinux-9): 1 days
        * vm_lnx_x86_64 (amazonlinux-2): 1 days
        * vm_lnx_x86_64 (amazonlinux-2023): 1 days
        * vm_lnx_x86_64 (debian-11): 1 days
        * vm_lnx_x86_64 (debian-12): 1 days
        * vm_lnx_x86_64 (fedora-40): 2 days
        * vm_lnx_x86_64 (opensuse-leap-15): 1 days
        * vm_lnx_x86_64 (oracle-7): 1 days
        * vm_lnx_x86_64 (oracle-8): 1 days
        * vm_lnx_x86_64 (oracle-9): 1 days
        * vm_lnx_x86_64 (rockylinux-8): 2 days
    * Branch: chef18: No job failures found.
```

As you can see the output is in markdown format suitable for posting in Slack,
or storing in Github.

There are a lot of options you can use to customize what is included in the
report.

### Configuration for `ci_stats.rb`

`ci_stats.rb` uses a Ruby-based configuration file powered by `mixlib-config`. This provides a flexible way to manage settings for analyzing CI statistics, pull requests, and issues.

**Processing Logic:**

The script determines which repositories to process based on a combination of command-line arguments and the `ci_stats_config.rb` file:

1.  **Specific CLI Target:** If both `--org ORG_NAME` and `--repo REPO_NAME` are provided as command-line arguments (both are required if one is used), `OssStats::CiStatsConfig.organizations` is internally reconfigured to represent *only* this single target repository for the current run. This overrides any `organizations` hash present in your `ci_stats_config.rb` file for target selection.
2.  **Iteration via Config File:** If `--org` and `--repo` are *not* provided via command line, the script uses the `organizations` hash defined in your `ci_stats_config.rb` file. If this hash is populated, the script will iterate through each repository listed under each organization defined therein.
3.  **Error on Partial CLI Target:** If only `--org` or only `--repo` is specified (but not both), the script will output an error message and exit, as both are required to define a specific target.
4.  **No Targets:** If neither `--org` nor `--repo` are given via CLI, AND the `organizations` hash in the `ci_stats_config.rb` file is empty or not defined, the script will log a message indicating no repositories are configured for processing and then exit.

**Configuration File Locations:**

The script will search for a configuration file named `ci_stats_config.rb` in the following locations, in order of precedence (first one found is used):

1.  Path specified by the `--config FILE_PATH` command-line option.
2.  `./ci_stats_config.rb` (in the current directory where the script is run).
3.  `~/.config/oss-stats/ci_stats_config.rb` (user-specific).
4.  `/etc/oss-stats/ci_stats_config.rb` (system-wide).

**Configuration Loading Order:**

The script builds its configuration (`OssStats::CiStatsConfig`) by loading settings in the following order, with later sources overriding earlier ones:
1.  **Hardcoded Defaults:** Initial default values for some parameters are defined directly in `src/lib/oss_stats/ci_stats_config.rb`.
2.  **`ci_stats_config.rb` File:** If a configuration file is found (see "Configuration File Locations"), its settings are loaded. Values in this file override the hardcoded defaults. This file defines global settings (e.g., `default_days 30`) and the `organizations` hash.
3.  **Command-Line Arguments (General Settings):** CLI options that modify general settings (e.g., `--days N`, `--log-level LEVEL`, but not targeting options like `--org` or `--repo`) are then applied. These override any values for those settings that came from the config file or hardcoded defaults. At this stage, `OssStats::CiStatsConfig` holds the global baseline configuration for the run.

**Order of Precedence for Effective Settings (for each processed repository):**

When the script processes a specific repository (either one targeted by CLI `--org`/`--repo` or one from the `organizations` hash during iteration), the actual settings used for that repository are determined by this hierarchy (higher items take precedence):
1.  **Repository-Specific settings (from `ci_stats_config.rb`):** e.g., `organizations['org1']['repositories']['repoA']['default_days'] = 10`.
2.  **Organization-Specific settings (from `ci_stats_config.rb`):** e.g., `organizations['org1']['default_days'] = 15`.
3.  **Global Setting Value (from `OssStats::CiStatsConfig`):** This is the final global value for an attribute after considering hardcoded defaults, file globals, and CLI global overrides. For example, if `--days 5` was used, `OssStats::CiStatsConfig.default_days` will be `5`, and this value is used if not overridden by repo or org-specific settings. If `--days` was not used, `OssStats::CiStatsConfig.default_days` would hold the value from the config file's global `default_days` or, if not set there, the hardcoded script default.
4.  **Hardcoded Defaults (from `src/lib/oss_stats/ci_stats_config.rb`):** These are the ultimate fallback if a setting is not defined at any of the higher levels. (Note: `default_org` and `default_repo` no longer have hardcoded defaults.)

**`ci_stats_config.rb` Structure and DSL Example:**

The configuration file uses a simple Ruby DSL. The `organizations` hash is the primary way to define multiple repositories for processing when not targeting a single repository via CLI `--org` and `--repo` arguments.

```ruby
# examples/ci_stats_config.rb

# === Global Settings in Config File ===
# These act as a baseline. They can be overridden by organization-specific settings,
# repository-specific settings, or global command-line arguments (e.g. --days 10).
# If a global CLI argument is provided, it updates the corresponding OssStats::CiStatsConfig
# attribute, which then becomes the baseline for the get_effective_settings logic.
#
# Note: `default_org` and `default_repo` are not meant to be set as global fallbacks
# in this file if the 'organizations' hash is empty and no CLI target is given;
# in that scenario, the script will exit.

default_branches ['main', 'master'] # Hardcoded default in script is ['main']
default_days 30                     # Hardcoded default in script is 30
log_level :info                     # Hardcoded default in script is :info
ci_timeout 600                      # Hardcoded default in script is 600 (10 minutes)
include_list false                  # Hardcoded default in script is false

# github_api_endpoint 'https://my.ghe.com/api/v3/'
# github_access_token 'your_token_here_from_config_file' # See token precedence below
# limit_gh_ops_per_minute 60.0

# === Organizations and Repositories for Iteration ===
# This hash is processed if --org and --repo are NOT specified on the command line.
# If this hash is empty or undefined, and no CLI target is given, the script will exit.
organizations(
  {
    'chef' => {
      # Organization-specific defaults for 'chef'
      'default_org' => 'chef', # Usually matches the hash key, for clarity
      'default_days' => 14,    # Overrides file-global `default_days` for chef/* repos
      'default_branches' => ['main', 'stable', 'current'], # Overrides file-global `default_branches`
      'ci_timeout' => 700,
      'include_list' => true,  # Overrides file-global `include_list`

      'repositories' => {
        'chef' => { # Defines settings for chef/chef
          'default_days' => 7, # Overrides 'chef' org's `default_days`
          'default_branches' => ['main', 'stable-18.2', 'stable-17.10'], # Overrides 'chef' org's `default_branches`
          'ci_timeout' => 900   # Overrides 'chef' org's `ci_timeout`
        },
        'ohai' => { # Defines settings for chef/ohai
          # Inherits days (14), ci_timeout (700), include_list (true) from 'chef' org
          'default_branches' => ['main'] # Overrides 'chef' org's `default_branches`
        }
      }
    },
    'sous-chefs' => {
      # Organization-specific defaults for 'sous-chefs'
      'default_org' => 'sous-chefs',
      'default_days' => 45,
      'default_branches' => ['main', 'master'],
      'log_level' => :debug, # This org's processing will be more verbose

      'repositories' => {
        'apache2' => { # Defines settings for sous-chefs/apache2
          # Inherits branches ['main', 'master'] from 'sous-chefs' org
          'default_days' => 60 # Overrides 'sous-chefs' org's `default_days`
        },
        'backup' => { # Defines settings for sous-chefs/backup
          # Uses all defaults from 'sous-chefs' org
        }
      }
    }
  }
)
```
(Refer to `examples/ci_stats_config.rb` for the most detailed and up-to-date example.)

### Command-Line Options:

*   `--org ORG_NAME`: GitHub organization name. **If used, `--repo` must also be specified.** When both are provided, they define the *single* repository to process for the run. This overrides iteration via the `organizations` hash in the config file.
*   `--repo REPO_NAME`: GitHub repository name. **If used, `--org` must also be specified.**
*   `--branches BRANCHES`: Comma-separated list of branches (e.g., `main,stable`). If specified, this acts as a **global override** by updating the `OssStats::CiStatsConfig.default_branches` setting for *all* processed repositories in that run. This new global baseline then participates in the standard settings precedence.
*   `-d DAYS, --days DAYS`: Number of days to analyze (e.g., `14`). Acts as a **global override** by updating `OssStats::CiStatsConfig.default_days`.
*   `--config CONFIG_FILE`: Path to a custom Ruby configuration file (e.g., `~/my_ci_stats_config.rb`).
*   `--ci-timeout TIMEOUT`: Timeout in seconds for CI processing. Acts as a **global override** by updating `OssStats::CiStatsConfig.ci_timeout`.
*   `--github-token TOKEN`: GitHub personal access token. This has the highest precedence for token provision (updates `OssStats::CiStatsConfig.github_access_token`).
*   `--github-api-endpoint ENDPOINT`: GitHub API endpoint (for GitHub Enterprise users). Overrides the value in `OssStats::CiStatsConfig`.
*   `--limit-gh-ops-per-minute RATE`: Rate limit GitHub API operations. Overrides the value in `OssStats::CiStatsConfig`.
*   `-l LEVEL, --log-level LEVEL`: Set logging level (debug, info, warn, error, fatal). Overrides the value in `OssStats::CiStatsConfig`.
*   `--mode MODE`: Controls which statistics to gather: `ci`, `pr`, `issue`. Use comma-separated values (e.g., `pr,issue`). `all` includes everything. (Default: `all`). This option applies to the entire run and is not layered per repository.
*   `--include-list`: Include detailed lists of PRs/Issues in the output. Acts as a **global override** by updating `OssStats::CiStatsConfig.include_list`.

### Environment Variables & GitHub Token:

The GitHub token is sourced by the `get_github_token!` helper function (from `lib/oss_stats/github_token.rb`) which checks the following sources in order and uses the first one found:
1.  The current value of `OssStats::CiStatsConfig.github_access_token` (this would have been set if `--github-token` was used on the CLI, or if `github_access_token` was defined in the `ci_stats_config.rb` file).
2.  The `GITHUB_TOKEN` environment variable.
3.  The token from GitHub CLI's `hosts.yml` file (`~/.config/gh/hosts.yml`).
The found token is then stored back into `OssStats::CiStatsConfig.github_access_token` for use by the Octokit client. If no token is found from any source, the script will log an error and exit.
If no token is found, the script will exit with an error.

## Meeting Stats

Many open source projects have weekly meetings and it's important to know
that the relevant teams are showing up and reporting the expected data.

The [meeting_stats.rb](src/meeting_stats.rb) script will allow you to record
the results of a meeting and then generate a report, including images with
trends over time.

You will **definitely** want a config file to make this useful for your
project, and you can see
[examples/meeting_stats_config.rb](examples/meeting_stats_config.rb) for an
example.

To update the stats for the week run `./src/meeting_stats.rb --mode record`,
and to update the report run `./src/meeting_stats.rb --mode generate`.

## Pipeline visibility stats

:warning: This is a Work In Progress! :warning:

Currently [pipeline_visibility_stats.rb](src/pipeline_visibility_stats.rb) only
supports Expeditor, which is Chef-specific and not open source. However, much
of the code is generic and this could be adapted to other things.

The idea here is to walk public repos and find tests that are not visible to
the public and report on them.

## Misc Promises

The [promises.rb](src/promises.rb) script allows you to add, edit, resolve,
abandon, and report on promises.

Example output:

```text
$ promises.rb
- Publish Chef 19 / 2025 plan (210 days ago)
- Fedora 41+ support (190 days ago)
```

You likely will probably want a config file for this as well and a sample
is provided in [examples/promises_config.rb](examples/promises_config.rb).
