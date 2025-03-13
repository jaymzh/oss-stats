# chef-oss-stats

[![Lint](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml)
[![DCO Check](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml)

This repo aims to track stats that affect how Chef Users ("the community") can
interact with Progress' development teams and repositories.

Stats from this repo will (hopefully) be published in the weekly slack meetings.

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
    Avg Time to Close PRs: 1.26 days

  Issue Stats (Last 1 days):
    Opened Issues: 0
    Closed Issues: 0
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
