# OSS Stats for <Project>

This repo aims to track stats that affect how <project>'s open source community
interacts with the project and repositories.

It leverages [oss-stats](https://github.com/jaymzh/oss-stats) to track those
stats. It assumes oss-stats and this repo are checked out next to each other
on the filesystem.

## tl;dr

* See **Issue, PR, and CI stats** in [ci_reports](ci_reports)
* See **weekly meeting stats** in [Slack Status Tracking](team_slack_reports.md)
* See **pipeline visiblity stats** in [pipeline_visibility_reports](pipeline_visibility_reports)
* See **promises** in [promises][promises]

## Issue, PR, and CI Status

### Description

One measure of project health is how often CI is broken. In addition, how long
PRs and Issues sit is another metric worth looking at. These are tracked adn
reported in [ci_reports](ci_reports).

### Updating the report

The [run_weekly_ci_reports.sh](run_weekly_ci_reports.sh) wrapper script runs
the `ci_stats` script on all relevant repos, and weekly we run that and put the
results in a dated file in the [ci_reports](ci_reports) directory.

## Meeting Stats

### Description

Another measure is whether there are updates in any sort of regular meeting.

We've asked that in that report the teams include the current CI status, and if
broken, what work is being done to fix it. These stats are collected weekly and
then generated into [mEeting Status Tracking](team_meeting_reports.md)

### Updating the report

To record a new meeting, run `../oss-stats/src/meeting_stats.rb -m record`.

To update the report with the new data, run `../oss-stats/src/meeting_stats.rb
-m generate`.

## Pipeline visibility stats

### Description

One common frustration among opensource contributors is that sometimes
Buildkite pipelines that run tests on PRs are private, so if they fail the
contributor cannot determine what the problem is.

The script to track this is currently not very generic and thus is probably
not used in this repo. Feel free to delete this section.

If there are stats, they are in
[pipeline_visibility_reports](pipeline_visibility_reports).

### Updating the report

Simply run `../oss-stats/src/pipeline_visibility_stats.rb`

## Promises

Promises are tracked in [Promises](promises).

Add a new promise with `promises.rb -m add-promise`, or run with no arguments
to get a report.
