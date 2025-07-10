# OSS Stats

[![Lint](https://github.com/jaymzh/oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/lint.yml)
[![Unittests](https://github.com/jaymzh/oss-stats/actions/workflows/unit.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/unit.yml)
[![DCO Check](https://github.com/jaymzh/oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/oss-stats/actions/workflows/dco.yml)
[![Gem Version](https://badge.fury.io/rb/oss-stats.svg)](https://badge.fury.io/rb/oss-stats)

This is a collection of tools that aim to make it easier to track and report
various metrics around health of an open source project.

* [Installation](#installation)
   * [Converting from pre-gem verions](#converting-from-pre-gem-versions)
* [Tools in this repo](#tools-in-this-repo)
   * [Repo Stats](#repo-stats)
   * [Pipeline Visibility Stats](#pipeline-visibility-stats)
   * [Meeting Stats](#meeting-stats)
   * [Promises](#promises)
* [Authentication](#authentication)

## Installation

You'll want to create your own directory or git repository to keep the data and
results that these scripts use and generate about your project. Whether or not
your directory is actually a git repo doesn't matter, but we recommend making
it one.

In your fresh directory, run this command to set everything up:

```bash
\curl -sSL https://raw.githubusercontent.com/jaymzh/oss-stats/refs/heads/main/bin/initialize_repo.sh | bash -s
```

You can pass in some options like:

```bash
\curl -sSL https://raw.githubusercontent.com/jaymzh/oss-stats/refs/heads/main/bin/initialize_repo.sh | bash -s -- <options>
```

You can find valid options with `-h`.

This will create a Gemfile that depends on the `git` version of the `oss-stats`
gem, install the bundle, setup the binstubs in `./bin`, create same config
files for you, and even setup GitHub Workflows!

You can run it with `-n` (dryrun) to see what it will do without actually
doing anything.

It'll look like:

```text
Welcome to oss-stats!

We'll go ahead and setup this directory to be ready to track your open source
stats!

➤ Initializing Gemfile to depend on oss-stats
➤ Installing gem bundle
➤ Making necessary directories
➤ Copying basic skeleton files
➤ Creating initial config files
➤ Setting up GH Workflows

OK, this directory is setup.

NEXT STEPS:

1. Edit `repo_stats_config.rb` in this directory to add repository to specify
   what repositories you care about, and change anything else you may be
   interested in.
2. Run a sample report with: `./bin/repo_stats.rb`

We recommend running it regularly (e.g. weekly) and storing the output in the
repo_reports directory we've created, ala:

  date=$(date '+%Y-%m-%d')
  out="repo_reports/${date}.md"
  for repo in $repos; do
    ./bin/repo_stats.rb >> $out
  done

Then you can also check `promise_stats`, `pipeline_visibility_stats`, and
`meeting_stats`.
```

You can see an example of a downstream repo at
[chef-oss-stats](https://github.com/jaymzh/chef-oss-stats/).

### Converting from pre-gem versions

If you ran the setup script before it used the gem (and required `../oss-stats`
to exist), you can convert to the new setup. Make sure your `oss-stats` checkout
is updated, and then run:

```bash
../oss-stats/bin/initialize_repo.sh -c
```

Once you've done that, your `oss-stats` checkout is no longer necessary.

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
