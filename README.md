# OSS Stats

[![Lint](https://github.com/jaymzh/oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/lint.yml)
[![Unittests](https://github.com/jaymzh/oss-stats/actions/workflows/unit.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/unit.yml)
[![DCO Check](https://github.com/jaymzh/oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/dco.yml)

This is a collection of tools that aim to make it easier to track and report
various metrics around health of an open source project.

* [How to use this repo](#how-to-use-this-repo)
* [Tools in this repo](#tools-in-this-repo)
   * [Repo Stats](#repo-stats)
   * [Pipeline Visibility Stats](#pipeline-visibility-stats)
   * [Meeting Stats](#meeting-stats)
   * [Promises](#promises)
* [Authentication](#authentication)

## How to use this repo

You'll want to create your own repository to keep the data and results that
these scripts use and generate about your project.

Currently docs and tools are all setup for you to keep your repo and this repo
checked out at the same level and use `oss-stats` directly from git. Once we
get a release out the door, we'll update this with alternative options.

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

You can see an example of a downstream repo at
[chef-oss-stats](https://github.com/jaymzh/chef-oss-stats/).

## Tools in this repo

### Repo Stats

[repo_stats](bin/repo_stats) is a tool designed to give a wide range of
statistics on everything from PRs response time to CI health. It supports both
GitHub and Buildkite and is highly configurable.

See [RepoStats.md](docs/RepoStats.md) for full details.

### Pipeline visibility stats

[pipeline_visibility_stats](bin/pipeline_visibility_stats) is a tool which
walks Buildkite pipelines associated with your public GitHub repositories to
ensure they are visible to contributors. It has a variety of options to
exclude pipelines intended to be private (for example, pipelines that may
have secrets to do pushes).

See [PipelineVisibilityStats.md](docs/PipelineVisibilityStats.md) for full
details.

### Meeting Stats

[meeting_stats](bin/meeting_stats) keeps track of things like meeting
attendance, and expected data to be provided. Currently it is somewhat
configurable, though the data it keeps track of isn't customizable.

`meeting_stats` will not just keep track of this data, it'll create graphs
of this data over time and overall reports.

See [MeetingStats.md](docs/MeetingStats.md) for full details.

### Promises

[promise_stats](bin/promise_stats) allows you to add, edit, resolve, abandon, and
report on promises made. This can be useful for both promises made to the
community or promises made between teams.

See [PromiseStats.md](docs/PromiseStats.md) for full details.

## Authentication

The scripts in this repo use a consistent mechanism for getting finding
the appropriate tokens to access the services in question.

### GitHub Token

Everything in this repo looks for your GitHub Access Token in the following
places, in order:

1. The `--github-token` command-line argument
1. The `github_token` config file entry
1. The `GITHUB_TOKEN` environment variable.
1. It'll also parse it from `~/.config/gh/hosts.yml` if you use the `gh` CLI tool.

### Buildkite Token

Everything in this repo looks for your BuildKite API token in the following
places, in order:

1. The `--buildkite-token` command-line argument
1. The `buildkite-token` config file entry
1. The `BUILDKITE_API_TOKEN` environment variable.

Your token will need GraphQL access.
