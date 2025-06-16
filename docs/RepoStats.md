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

See [examples/repo_stats_config.rb](../examples/repo_stats_config.rb) for details.

## Threshold Filtering

When working with a large number of repositories, the output of `repo_stats.rb`
can become quite verbose. Threshold filtering options allow you to narrow down
the report to include only the top N or N% of repositories based on specific
criteria. This helps in identifying areas that might need the most attention.

If multiple threshold options are provided, repositories meeting *any* of the
specified criteria will be included in the report.

Percentages (`N%`) are calculated based on the total number of repositories
being processed in the current run. For example, if 20 repositories are being
processed and `--top-n-stale=10%` is used, the top 2 repositories (10% of 20)
will be selected for that criterion.

The following threshold filtering options are available:

* `--top-n-stale=N` or `N%`: Includes the top N or N% of repositories based
  on the *maximum* stale count of either its Pull Requests or Issues (stale
  is defined as >30 days without a comment). For example, if a repo has 5
  stale PRs and 10 stale Issues, it's ranked by 10.
* `--top-n-oldest=N` or `N%`: Includes the top N or N% of repositories with
  the oldest open item (Pull Request or Issue). The age of the single oldest
  item (be it a PR or an Issue) in a repository is used for comparison.
* `--top-n-time-to-close=N` or `N%`: Includes the top N or N% of repositories
  with the highest average time-to-close. The ranking uses the *higher* of
  the average time-to-close for Pull Requests or the average time-to-close
  for Issues within a repository.
* `--top-n-stale-pr=N` or `N%`: Includes the top N or N% of repositories with
  the most stale Pull Requests.
* `--top-n-stale-issue=N` or `N%`: Includes the top N or N% of repositories
  with the most stale Issues.
* `--top-n-oldest-pr=N` or `N%`: Includes the top N or N% of repositories
  with the oldest open Pull Requests.
* `--top-n-oldest-issue=N` or `N%`: Includes the top N or N% of repositories
  with the oldest open Issues.
* `--top-n-time-to-close-pr=N` or `N%`: Includes the top N or N% of
  repositories with the highest average time-to-close for Pull Requests.
* `--top-n-time-to-close-issue=N` or `N%`: Includes the top N or N% of
  repositories with the highest average time-to-close for Issues.
* `--top-n-most-broken-ci-days=N` or `N%`: Includes the top N or N% of
  repositories with the highest total number of days CI jobs were reported as
  broken across all checked branches.
* `--top-n-most-broken-ci-jobs=N` or `N%`: Includes the top N or N% of
  repositories with the highest number of distinct CI jobs that were reported
  as broken across all checked branches.
