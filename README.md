# chef-oss-stats

[![Lint](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/lint.yml)
[![DCO Check](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml/badge.svg)](https://github.com/jaymzh/chef-oss-stats/actions/workflows/dco.yml)

This repo aims to track stats that affect how Chef Users ("the community") can
interact with Progress' development teams and repositories.

Stats from this repo will (hopefully) be published in the weekly slack meetings.

## Automatic stats tracked

* Build-status. Run [chef-ci-status.py](src/chef-ci-status.py)
  Will generate stats for last 30 days by default. Defaults to chef/chef, 30 days, both `main` and `chef-18`, but highly configutable. Output is number of days, out of the last 30, any workflow was broken:
```shell
$ ./chef-repo-build-status.rb --days 1
Days each job was broken in the last 1 days:

Branch: chef-18
  vm_lnx_x86_64 (almalinux-8): 1 days
  vm_lnx_x86_64 (rockylinux-9): 1 days
  unit: 1 days
  docr_lnx_x86_64 (rockylinux-8): 1 days

Branch: main
  docr_lnx_x86_64 (debian-12): 1 days
  vm_lnx_x86_64 (oracle-8): 1 days
```

* [Slack Status Tracking](team_slack_reports.md)

## Manual or semi-manual stats

* [Misc stats](manual_stats/misc.md)
