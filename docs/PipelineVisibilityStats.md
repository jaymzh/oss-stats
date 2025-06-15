# Pipeline visibility stats

[pipeline_visibility_stats](../bin/pipeline_visibility_stats.rb) is a tool
which walks Buildkite pipelines associated with your public GitHub repositories
to ensure they are visible to contributors. It has a variety of options to
exclude pipelines intended to be private (for example, pipelines that may have
secrets to do pushes).

There are two providers: buildkite and expeditor. Expeditor is deprecated
and will go away.

## Buildkite Provider

This attempts to find improperly configured pipelines in two ways:

* Given the buildkite repo, gets a list of all pipelines and builds a
  map of GitHub Repos to pipelines. Then, it walks all GH repos
  repos (either in the GH Org, or specified in the config), and checks
  to see if there are buildkite repos associated with it, and if there are,
  checks their visibility settings
* Walks the most recent 10 PRs, and checks for any status checks that are
  on buildkite, and checks if it can see them, and if so, checks their
  visibility (it reporst them as private if it cannot see them)

This is likely to include pipelines expected to be public such as those
added adhoc to specific PRs to do builds. You can use --skip to add skip
patterns (partial-match text) to avoid counting those.

Example output looks like (this is truncated for brevity):

```markdown
# Chef Pipeline Visibility Report 2025-06-14

* [chef/chef-cli](https://github.com/chef/chef-cli)
    * chef/chef-chef-cli-main-habitat-test
* [chef/chef-foundation](https://github.com/chef/chef-foundation)
    * chef/chef-chef-foundation-main-verify
* [chef/chef-powershell-shim](https://github.com/chef/chef-powershell-shim)
    * chef/chef-chef-powershell-shim-pipeline-18-stable-habitat-build
    * chef/chef-chef-powershell-shim-pipeline-stable-18-verify
```

At a minimum you will need the optoins `--github-org` and `--buildkite-org`.

## Expeditor Provider

The Expeditor Provider parses expeditor configs, which is Chef-specific and not
open source. However, much of the code is generic and this could be adapted to
other things.

If you do want to use it, you can do so with `--provider=expeditor`.
