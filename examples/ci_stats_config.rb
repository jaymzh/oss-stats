# frozen_string_literal: true
#
# Example configuration file for ci_stats.rb using mixlib-config
#
# This file demonstrates how to configure global settings and settings for
# multiple organizations and repositories. The script will iterate through
# repositories defined in the `organizations` hash unless specific `--org` and
# `--repo` command-line arguments are provided.
#
# Copy this to one of the default locations or specify its path with --config:
# - ./ci_stats_config.rb (current directory)
# - ~/.config/oss-stats/ci_stats_config.rb (user specific)
# - /etc/oss-stats/ci_stats_config.rb (system wide)

# === Global Defaults ===
# These apply if not overridden by organization/repository specific settings
# or global CLI arguments that target these specific settings.
#
# Note: `default_org` and `default_repo` are NOT defined as global defaults here.
# If the `organizations` hash below is empty or not defined, and you are not
# providing `--org` and `--repo` via CLI, the script will have no targets.

default_branches ['main', 'master'] # Default: ['main'] in the script if nothing else is set
default_days 30                     # Default: 30 in the script
log_level :info                     # Default: :info in the script
ci_timeout 600                      # Default: 600 (10 minutes) in the script
include_list false                  # Default: false in the script

# GitHub API endpoint (for GitHub Enterprise). If nil, uses public GitHub.
# github_api_endpoint 'https://my.ghe.com/api/v3/'

# GitHub Access Token.
# Order of precedence:
# 1. --github-token CLI option
# 2. `github_access_token` set in this file
# 3. GITHUB_TOKEN environment variable
# 4. Token from GitHub CLI's hosts.yml file
# It's often best to use ENV['GITHUB_TOKEN'] or gh CLI.
# github_access_token 'your_personal_access_token_here_if_not_using_env'

# Optional: Limit GitHub API operations made directly by this script.
# limit_gh_ops_per_minute 60.0


# === Organization and Repository Specific Settings ===
#
# This `organizations` hash is the primary way to define targets for iteration
# when NOT using specific `--org` and `--repo` CLI arguments.
# Settings are layered:
# Global CLI options (e.g. --days) > Repo-specific > Org-specific > File global > Hardcoded script defaults.

organizations(
  {
    'chef' => {
      # Defaults for all repositories under the 'chef' organization
      'default_org' => 'chef', # For clarity/consistency, often matches the hash key
      'default_days' => 14,    # Look back 2 weeks for most Chef repos
      'default_branches' => ['main', 'stable', 'current'], # Common branches for Chef
      'ci_timeout' => 750,     # Slightly longer CI timeout for Chef repos
      'include_list' => true,  # Show PR/Issue lists for Chef repos by default

      'repositories' => {
        'chef' => { # Processes chef/chef
          'default_days' => 7,  # Override org's default_days
          'default_branches' => ['main', 'stable-18.2', 'stable-17.10'], # Override org's branches
          'ci_timeout' => 900   # Override org's ci_timeout
        },
        'ohai' => { # Processes chef/ohai
          # Inherits 'default_days' (14) and 'ci_timeout' (750) from 'chef' org.
          # Inherits 'include_list' (true) from 'chef' org.
          'default_branches' => ['main'] # Override org's branches
        },
        'chef-analyze' => { # Processes chef/chef-analyze
          # This repository will use effective settings:
          # default_days: 14 (from 'chef' org)
          # default_branches: ['main', 'stable', 'current'] (from 'chef' org)
          # ci_timeout: 750 (from 'chef' org)
          # include_list: true (from 'chef' org)
        }
        # Add other repositories under 'chef' here
      }
    },
    'sous-chefs' => {
      # Defaults for all repositories under the 'sous-chefs' organization
      'default_org' => 'sous-chefs',
      'default_days' => 45,             # Longer lookback for Sous-Chefs cookbooks
      'default_branches' => ['main', 'master'], # Common branches in Sous-Chefs
      'log_level' => :debug,            # Org-specific logging for processing this org

      'repositories' => {
        'apache2' => { # Processes sous-chefs/apache2
          # Inherits 'default_branches' (['main', 'master']) from 'sous-chefs' org.
          # Inherits 'log_level' (:debug) from 'sous-chefs' org.
          'default_days' => 60 # Override org's default_days
        },
        'backup' => { # Processes sous-chefs/backup
          # Uses all defaults from 'sous-chefs' org (days: 45, branches: ['main', 'master'], etc.)
        }
        # Add other repositories under 'sous-chefs' here
      }
    },
    'empty-org-example' => {
      # This organization has no repositories defined in its 'repositories' hash.
      # If the script iterates, it will effectively skip this org as no repos are listed.
      'default_days' => 5 # This setting would apply if repos were listed here
    }
    # Add other organizations here if you want them processed during iteration.
  }
)

# Example of how to set a specific global config value directly (less common for this file)
# log_level :debug
# default_days 20 # This would be a global default if not overridden elsewhere.
