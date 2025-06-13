# Example configuration file for ci_stats

# You can specify branches for specific repos under 'organizations'
# below, but for anything not specified it'll use `default_branches`
# (which defaults to ['main']
default_branches %w{main v2}
default_days 30
log_level :info
ci_timeout 600
include_list false

# the most interesting part about this config file
# is the organizations block. It allows you to specify
# all of the repos that will be processed and how
# they should be processed
organizations({
  'someorg' => {
    # if this org uses different branches by default
    'default_branches' => ['trunk'],
    # if you want a different number of days by default for repos in this org
    'default_days' => 7,
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
    'default_days' => 45,
    'default_branches' => %w{main oldstuff},
    'repositories' => {
      'repo1' => {},
      'repo2' => {},
      'repo3' => {},
    },
  },
})
