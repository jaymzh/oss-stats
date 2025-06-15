# Example configuration file for repo_stats

# You can specify branches for specific repos under 'organizations'
# below, but for anything not specified it'll use `default_branches`
# (which defaults to ['main'])
#
# Note do NOT set 'days' or 'branches' in your config, as that overrides
# everything and is meant for CLI options.
default_branches %w{main v2}
default_days 30
# you can specify 'days', but it will override everything, including
# anything repo-specific below, so don't do that.
log_level :info
ci_timeout 600
include_list false

# the most interesting part about this config file
# is the organizations block. It allows you to specify
# all of the repos that will be processed and how
# they should be processed
organizations({
  'someorg' => {
    # if this org uses different branches (can further override under the repo)
    'branches' => ['trunk'],
    # if you want a different number of days by for repos in this org (can
    # further override under the repo)
    'days' => 7,
    'repositories' => {
      'repo1' => {},
      'repo2' => {
        # crazy repo, only do 2 days
        'days' => 2,
        'branches' => ['main'],
      },
      'repo3' => {
        'days' => 30,
        'branches' => ['main'],
      }
  },
  'anotherorg' => {
    'days' => 45,
    'branches' => %w{main oldstuff},
    'repositories' => {
      'repo1' => {},
      'repo2' => {},
      'repo3' => {},
    },
  },
})
