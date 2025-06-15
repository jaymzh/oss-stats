# Repo Stats

[repo_stats](../bin/repo_stats.rb) is a tool designed to give a wide range of
statistics on everything from PRs response time to CI health. It supports both
GitHub and Buildkite and is highly configurable.

It will walk all configured repos in all configured organizations and gather
the desired statistics and print them out in Slack-friendly Markdown.

The tool has 3 modes, and by default runs all 3 (aka `all` mode):

* CI
* PR
* Issue

For each mode, it pulls statistics for the last N days (default: 30).

We'll look at each mode in detail in the sections below.

**NOTE**: These examples specify a single GH Organization and GH Repository on
the command line, but most people will want to use the configuration file to
configure a list of org/repos to walk.

## CI mode

The CI mode walks all CI related to the repositires in question and reports
the number of days they were broken on each branch desired (default: main).

It discovers both GitHub Actions workflows as well as Buildkite Pipelines.  For
Buildkite pipelines, the tool will pull all pipelines in the specified
Buildkite Organization and map them to GitHub repos. In addition, it'll check
the README on every repo it examines and look for any badges that point to a
Buildkite pipeline and attempt to pull status of that (even if it is in a
different Buildkite organization).

For a single repository with both GitHub and Buildkite checks, this is
sample output:

```markdown
*_[chef/chef](https://github.com/chef/chef) Stats (Last 7 days)_*

* CI Stats:
    * Branch: `main` has the following failures:
        * Dependabot Updates / Dependabot: 5 days
        * [BK] chef-oss/chef-chef-main-habitat-test: 3 days
        * [BK] chef-oss/chef-chef-main-verify: 3 days
```

If there is no `--buildkite-org` passed in, no attempt will be made to find
or check any Buildkite pipelines.

## PR and Issues modes

These modes work the same way, but report on PRs or Issues, respectively.
They gather a variety of statistics, and here's some sample output when
both modes are active:

```markdown
*_[chef/chef](https://github.com/chef/chef) Stats (Last 7 days)_*

* PR Stats:
    * Closed PRs: 5
    * Open PRs: 38 (6 opened this period)
    * Oldest Open PR: 2025-03-03 (103 days open, last activity 84 days ago)
    * Stale PR (>30 days without comment): 15
    * Avg Time to Close PRs: 3.02 days

* Issue Stats:
    * Closed Issues: 0
    * Open Issues: 8 (1 opened this period)
    * Oldest Open Issue: 2025-03-06 (100 days open, last activity 72 days ago)
    * Stale Issue (>30 days without comment): 5
    * Avg Time to Close Issues: 0 hours
```

## Configuration File

Unless you only have single repository you're interested in, you'll need to
make a configuration file if you don't want to have to run `repo_stats`
repeatedly. It allows you to specify orgs, repos within those orgs, and
customize branches to check and days to report on by repo.

See [examples/ci_stats_config.rb](../examples/ci_stats_config.rb) for details.
