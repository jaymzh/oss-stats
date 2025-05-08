#!/bin/bash

DRYRUN=0
FORCE=0

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

cat <<EOF
This script will initialize a new repo that utilizes oss-stats. It should
be run in an empty directory, or new git clone.
EOF

while getopts fhn opt; do
    case "$opt" in
        h)
            usage
            exit
            ;;
        n)
            DRYRUN=1
            ;;
        f)
            FORCE=1
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

mydir="$(dirname $(realpath $0))"
echo "Making necessary directories"
mkdir -p data ci_reports pipeline_visibility_reports promises images \
    .github/workflows
echo "Copying basic config files..."
for file in $(find $mydir/../initialization_data/ -maxdepth 1 -type f); do
    if [[ "$file" =~ rubocop.yml ]]; then
        run cp "$file" .rubocop.yml
    else
        run cp "$file" .
    fi
done
echo "Setting up GH Workflows"
run cp "$mydir/../initialization_data/github_workflows/"* ./.github/workflows
