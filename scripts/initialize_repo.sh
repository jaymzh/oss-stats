#!/bin/bash

MYDIR="$(dirname $(realpath $0))"
DRYRUN=0
FORCE=0
DIRS=(
    data
    repo_reports
    pipeline_visibility_reports
    promises
    images
    .github/workflows
)

warn() {
    echo "WARNING: $*"
}

err() {
    echo "ERROR: $*"
}

die() {
    err "$@"
    exit 1
}

run() {
    if [[ "$DRYRUN" -ne 0 ]]; then
        echo "DRYRUN: $*"
        return
    fi
    "$@"
}

usage() {
    cat <<EOF
$0 <options>

This script will initialize a new repo that utilizes oss-stats. It should
be run in an empty directory, or new git clone.

Options:
    -f
            Force. Copy over files, even if the directory is not empty.
    -n
            Dryrun. Don't do any work, just say what you would do.
    -h
            Print this help message.
EOF
}

while getopts fhn opt; do
    case "$opt" in
        d)
            DEBUG=1
            ;;
        f)
            FORCE=1
            ;;
        h)
            usage
            exit
            ;;
        n)
            DRYRUN=1
            ;;
        ?)
            exit 1
            ;;
    esac
done

num=$(ls | wc -l)
if [[ "$num" -ne 0 ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        warn "Directory not empty, but force is on"
    else
        die "Script should be run in an empty directory"
    fi
fi

cat <<'EOF'
Welcome to oss-stats!

We'll go ahead and setup this directory to be ready to track your open source
stats!

EOF

echo "=> Making necessary directories"
run mkdir -p "${DIRS[@]}"

echo "=> Copying basic skeleton files"
for file in $(find "$MYDIR/../initialization_data/" -maxdepth 1 -type f); do
    dst=$(basename "$file")
    if [[ "$dst" ==  'rubocop.yml' ]]; then
        dst='.rubocop.yml'
    fi
    run cp "$file" "$dst"
done

echo "=> Copying sample config files"
run cp "$MYDIR/../examples/"*_config.rb .

echo "=> Setting up GH Workflows"
run cp "$MYDIR/../initialization_data/github_workflows/"* ./.github/workflows

cat <<'EOF'

OK, this directory is setup. Your next step is to modify the config files in
this directory, and do an initial run. Generally the first script people are
interested in would be run like:

  ../oss-stats/bin/repo_stats.rb --org <YOUR_ORG> --repo <SOME_REPO>

We recommend running it regularly (e.g. weekly) and storing the output in the
repo_reports directory we've created, ala:

  date=$(date '+%Y-%m-%d')
  out="repo_reports/${date}.md"
  for repo in $repos; do
    ../oss-stats/bin/repo_stats.rb --org <YOUR_ORG> --repo $repo >> $out
  done

EOF
