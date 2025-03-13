#!/bin/bash

REPO_SCRIPT=chef_ci_status.rb
MYDIR="$(dirname $(realpath $0))"
REPO_SCRIPT_PATH="$MYDIR/$REPO_SCRIPT"

# infra-client
chef_repos=(
    chef
    ohai
    cheffish
    cookstyle
    cookstylist
    chef-plans
    vscode-chef
    chef-powershell-shim
    mixlib-shellout
    mixlib-archive
    mixlib-versioning
    mixlib-log
    mixlib-install
    mixlib-config
    mixlib-cli
    win32-service
    win32-certstore
    win32-ipc
    win32-taskscheduler
    win22-process
    win32-event
    win32-api
    win32-eventlog
    ffi-win32-extensions
    chef-zero
    ffi-yajl
    fauxhai
)

# automate
chef_repos+=(
    automate
    chef-manage
)

# workstation
chef_repos+=(
    chef-workstation
)

# chef-server
chef_repos+=(
    chef-server
    erlang-bcrypt
    chef_authn
    chef_reg
    chef_secrets
    efast_xs
    epgsql
    erlzmq2
    fixie
    folsom_graphite
    ibrowse
    mini_s3
    mixer
    moser
    opscoderl_folsom
    opscoderl_httpc
    opscoderl_wm
    sqerl
    stats_hero
    knife-ec-backup
)

# habitat
habitat_repos=(
    habitat
    core-plans
    homebrew-habitat
)

chef_repos+=(
    chef-base-plans
)

# inspect
inspec_repos=(
    inspect
    inspec-digital-ocean
    inspec-habitat
    inspec-oneview
    inspec-vmware
    kitchen-inspec
    train-aws
    train-habitat
    train-digitalocean
    inspec-aws
    inspec-azure
    inspec-gcp
)

if [[ "$*" =~ '--help' ]] || [[ "$*" =~ 'h' ]]; then
    cat <<EOF
This is a dumb wrapper around ${REPO_SCRIPT}!

It has no options itself. It will call $REPO_SCRIPT for all repos
it knows about. It will pass any options to this script to all calls
to $REPO_SCRIPT.
EOF
    exit
fi

cat <<EOF
# Weekly Chef Repo Statuses

If you see a deprecated repo or don't see a current repo, please update the
repo lists in
[chef-oss-practices/projects](https://github.com/chef/chef-oss-practices/tree/main/projects)
and
[chef/community_pr_review_checklist](https://github.com/chef/chef/blob/main/docs/dev/how_to/community_pr_review_checklist.md) and then file an Issue (or PR) in [jaymzh/chef-oss-stats](https://github.com/jaymzh/chef-oss-stats).

EOF

for repo in "${chef_repos[@]}"; do
    args=("--repo=$repo")
    if [ $repo = 'chef' ] || [ $repo = 'ohai' ]; then
        args+=("--branches=main,chef18")
    fi
    $REPO_SCRIPT_PATH "${args[@]}" --repo $repo "${@}"
    echo
done

for repo in "${habitat_repos[@]}"; do
    $REPO_SCRIPT_PATH --org habitat-sh --repo $repo "${@}"
    echo
done

for repo in "${inspec_repos[@]}"; do
    $REPO_SCRIPT_PATH --org inspec --repo $repo "${@}"
    echo
done
