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
