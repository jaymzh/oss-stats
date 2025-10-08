## OSS-Stats — Copilot instructions (concise)

Purpose: help an AI coding agent become productive quickly in this Ruby repo.

Core orientation
- This repository is a small Ruby toolkit that collects repository metrics
  (PRs, Issues, CI health, meeting stats, promises). Primary entry points are
  the CLI scripts in `bin/` (for consumers) and the library under `lib/oss_stats`.
- Key files to read first:
  - `lib/oss_stats/repo_stats.rb` — the main data-gathering mixin/CLI logic.
  - `lib/oss_stats/github_client.rb` — direct GitHub REST calls used when
    Octokit isn't sufficient.
  - `lib/oss_stats/buildkite_client.rb` — Buildkite GraphQL client and pagination.
  - `lib/oss_stats/config/*.rb` — Mixlib::Config-based configuration and lookup.
  - `bin/initialize_repo.sh` and the `bin/*` scripts — how downstream projects
    are bootstrapped and the recommended runtime scripts.

Big-picture architecture & data flow (short)
- CLI/runner (e.g. `./bin/repo_stats.rb`) -> load config (Mixlib::Config) ->
  create GitHub/Buildkite clients -> fetch data (issues, PRs, workflow runs,
  Buildkite builds) -> compute stats -> print markdown reports.
- Config merging order for effective repo settings: CLI options > repo config >
  org config > global defaults (`default_days`, `default_branches`). See
  `get_effective_repo_settings` in `lib/oss_stats/repo_stats.rb`.
- Token precedence (important):
  1. CLI flags (`--github-token`, `--buildkite-token`)
  2. values from the loaded config file
  3. environment variables (`GITHUB_TOKEN`, `BUILDKITE_API_TOKEN`)
  4. GitHub host parsing (`~/.config/gh/hosts.yml`) if available

Project-specific conventions and patterns
- Config discovery: uses `find_config_file('repo_stats_config.rb')` implemented
  in `lib/oss_stats/config/shared.rb`. Look for config in CWD, `$HOME/.config/oss_stats`, or `/etc`.
- Logging: all modules use `OssStats::Log` (helper `log` is defined in `lib/oss_stats/log.rb`).
  Respect `log.level` and prefer the `log` helper when adding messages.
- Output: CLI can disable markdown links with the `--no-links` (or
  `RepoStats.no_links`) option. Many tests depend on the exact textual output
  format, so small changes to messages or link formatting can break tests.
- Rate limiting: the code supports `limit_gh_ops_per_minute` which causes
  `rate_limited_sleep` to sleep between GitHub calls. When adding GH API calls,
  reuse that helper to avoid rapid-fire requests.

Integration and external dependencies (observed)
- GitHub: mostly via Octokit in tests and code paths; a lightweight `GitHubClient`
  is used for some raw REST calls (see `pr_statuses` and `recent_prs`).
- Buildkite: GraphQL endpoint is used via `BuildkiteClient#execute_graphql_query`.
  Buildkite token must have GraphQL access.
- Gems of note: `octokit`, `mixlib-config`, `mixlib-log`, `deep_merge`. See
  `Gemfile` for exact versions.

Testing and developer workflows (exact commands)
- Install deps and run tests with bundler and the repo scripts:

```bash
# install gems
bundle install

# run unit tests (uses RSpec, see `scripts/run_specs.sh`)
./scripts/run_specs.sh

# lint Ruby (cookstyle), Markdown, and shell scripts
./scripts/run_cookstyle.sh
./scripts/run_markdownlint.sh
./scripts/run_shellcheck.sh
```

Notes about tests: RSpec uses method doubles and mocks for Octokit and
Buildkite clients (see `spec/*.rb`). Tests expect specific method names like
`issues`, `workflow_runs`, `workflow_run_jobs`, and Buildkite GraphQL helpers.
Avoid changing APIs without updating specs.

Common runtime patterns & CLI options
- Default runner: `./bin/repo_stats.rb` (run from a project directory created
  by `bin/initialize_repo.sh`).
- Important CLI options referenced in code:
  - `--config <file>` - explicit config file
  - `--github-token` / `--buildkite-token`
  - `--days` / `--default-days`, `--branches` / `--default-branches`
  - `--no-links` - disable markdown links in output
  - `--limit-gh-ops-per-minute` - throttle GH API calls
  - `--mode` - `ci,pr,issue,all` controls which sections are gathered

Repo-readme Buildkite detection detail (useful for fixes/enhancements)
- The code attempts to find Buildkite pipelines by scanning README contents
  for Buildkite badge links (see `pipelines_from_readme` in `lib/oss_stats/repo_stats.rb`).
  Expect badge links like:

  - `[![Build Status](badge.svg)](https://buildkite.com/org/pipeline)`
  - variants (no alt text or different image markdown) are already handled;
    if you change the parser, run the Buildkite-related specs.

What to watch for when editing
- Preserve public CLI flags and config behavior; tests assert specific
  behaviors and output strings.
- When adding new API calls, use existing clients (`GitHubClient`,
  `BuildkiteClient`) and follow token/endpoint patterns.
- Keep logging consistent via `OssStats::Log` and prefer debug/info/warn levels
  appropriately.

Where to look for more context
- `README.md` (top-level) — user-facing install and usage patterns.
- `docs/` — longer design notes per tool (RepoStats, PromiseStats, etc.).
- `initialization_data/` — example GH workflow files and the bootstrap behavior
  used by `bin/initialize_repo.sh`.

If anything here is unclear or you'd like examples tailored to a specific
change (e.g., add a new GitHub API call, change output format, or add a test),
tell me which area and I will extend this file with targeted examples.
