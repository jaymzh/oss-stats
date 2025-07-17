#!/bin/bash

CONVERT=0
DRYRUN=0
DEBUG=0
FORCE=0
BRANCH=""
NOGIT=0
VERSION=""
DIRS=(
    scripts
    data
    repo_reports
    pipeline_visibility_reports
    promises
    images
    .github/workflows
)
OSS_STATS_PATH=""

step() {
    echo "➤ $*"
}

warn() {
    echo "WARNING: $*" >&2
}

err() {
    echo "ERROR: $*" >&2
}

die() {
    err "$@"
    exit 1
}

debug() {
    [[ "$DEBUG" -eq 0 ]] && return

    echo "DEBUG: $*" >&2
}

run() {
    if [[ "$DRYRUN" -ne 0 ]]; then
        echo "DRYRUN: $*"
        return 0
    fi
    "$@"
}

usage() {
    cat <<EOF
$0 <options>

This script will initialize a new repo that utilizes oss-stats. It should
be run in an empty directory, or new git clone.

Options:
    -b <branch>
            Install oss-stats gem from a specific branch. You probably do
            not want this.

    -c
            Convert Mode. If you setup oss-stats back when it required
            a checkout of your downstream repo and oss-stats next to each
            other, you can use this option to convert your repo to use the
            gem instead.

    -d
            Enable debug output.

    -f
            Force. Copy over files, even if the directory is not empty. Not
            recommended.

    -G
            When installing oss-stats, don't use git, instead use wahtever
            is latest. Not recommended. See also '-V'.

    -h
            Print this help message.

    -n
            Dryrun. Don't do any work, just say what you would do.

    -V <version_constraint>
            When installing oss-stats, don't use git, and specifically use
            this version of the gem. Must be in gem-constraint format.

EOF
}

do_gem() {
    step "Initializing Gemfile to depend on oss-stats"
    if [ "$CONVERT" -eq 1 ]; then
        run rm Gemfile Gemfile.lock
    fi
    gemfile_line="gem 'oss-stats'"
    if [[ -n "$VERSION" ]]; then
        gemfile_line="$gemfile_line, $VERSION"
    elif [[ "$NOGIT" -eq 0 ]]; then
        gemfile_line="$gemfile_line,\n  git: 'https://github.com/jaymzh/oss-stats.git'"
        if [[ -n "$BRANCH" ]]; then
            gemfile_line="$gemfile_line,\n  branch: '$BRANCH'"
        fi
    fi

    if [ -e Gemfile ] && [ "$CONVERT" -eq 0 ]; then
        if grep -q 'oss-stats' Gemfile; then
            warn "Gemfile already populated with oss-stats, skipping"
        else
            warn "Gemfile already exists, adding oss-stats"
            if [ "$DRYRUN" -eq 0 ]; then
                echo -e "$gemfile_line" >> Gemfile
            fi
        fi
    else
        cat >Gemfile <<EOF
source 'https://rubygems.org'

$(echo -e "$gemfile_line")

group(:development) do
  gem 'cookstyle'
  gem 'mdl'
  gem 'rspec'
end
EOF
    fi

    step 'Installing gem bundle'
    if ! out=$(run bundle install); then
        die "Failed to install bundle. Output: \n$out"
    fi
    if ! out=$(run bundle update oss-stats); then
        die "Failed to install latest oss-stats. Output: \n$out"
    fi
    run bundle binstubs oss-stats
    OSS_STATS_PATH=$(bundle show oss-stats)
}

do_directories() {
    step 'Making necessary directories'
    run mkdir -p "${DIRS[@]}"
}

gen_file() {
    local file="$1"
    local content="$2"

    if [ -e "$file" ]; then
        warn "$file exists, skipping"
        return
    fi

    if [ "$DRYRUN" -eq 0 ]; then
        echo -e "$content" > "$file"
    else
        echo "DRYRUN: echo \"$content\" > $file"
    fi
}

do_files() {
    local dst
    local file
    step 'Copying basic skeleton files'

    # top level files
    mapfile -t files < <(
        find "$OSS_STATS_PATH/initialization_data/" -maxdepth 1 -type f
    )
    debug "Copying files: ${files[*]}"
    for file in "${files[@]}"; do
        dst=$(basename "$file")
        run cp "$file" "$dst"
    done

    # scripts
    mapfile -t files< <(
        find "$OSS_STATS_PATH/initialization_data/scripts" -maxdepth 1 -type f
    )
    debug "Copying scripts: ${files[*]}"
    for file in "${files[@]}"; do
        dst=$(basename "$file")
        run cp "$file" "scripts/$dst"
        chmod +x "scripts/$dst"
    done
}

do_config_files() {
    step 'Creating initial config files'
    for file in "$OSS_STATS_PATH/examples/"*_config.rb; do
        f=$(basename "$file")
        # even if we're in force/convert, skip config files that exist
        if [ -e "$f" ]; then
            warn "Config file $f already exists, skipping"
        else
            run cp "$file" .
        fi
    done
}

do_gh_workflows() {
    step 'Setting up GH Workflows'
    for file in "$OSS_STATS_PATH/initialization_data/github_workflows/"*; do
        f=".github/workflows/$(basename "$file")"
        run cp "$file" "$f"
    done
}

do_instructions() {
    if [ "$CONVERT" -eq 1 ]; then
        do_convert_instructions
    else
        do_install_instructions
    fi
}

do_install_instructions() {
    cat <<'EOF'
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
`meeting_stats` - these are all in `./bin`
EOF
}

do_convert_instructions() {
    cat <<'EOF'
We've done our best to convert your repo. Some things to check for:

* You probably will want to revert to your README if you've made changes,
  so run `git diff README.md`, and optionally `git checkout README.md`
* If you have your own CI stuff, be sure to checkout the changes to the
  github workflow files
* New stuff is in bin/ and scripts/ - be sure to git add them
* Finally, do a pass on `git diff` and `git status`, to make sure you like
  what you see.

From now on, run script with `./bin/<script>` instead of
`../oss-stats/bin/<script>` and other than that, it should be the same!
EOF
}

while getopts b:cdfGhnV: opt; do
    case "$opt" in
        b)
            BRANCH="$OPTARG"
            ;;
        c)
            debug "Activating CONVERT mode"
            CONVERT=1
            ;;
        d)
            debug "Activating DEBUG mode"
            DEBUG=1
            ;;
        f)
            debug "Activating FORCE mode"
            FORCE=1
            ;;
        G)
            NOGIT=1
            ;;
        h)
            usage
            exit
            ;;
        n)
            DRYRUN=1
            ;;
        V)
            VERSION="$OPTARG"
            ;;
        ?)
            exit 1
            ;;
    esac
done

# shellcheck disable=SC2012
num=$(ls | wc -l)
if [[ "$num" -ne 0 ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        warn "Directory not empty, but force is on"
    elif [[ "$CONVERT" -eq 1 ]]; then
        warn "Directory not empty, but convert is on"
    else
        die "Script should be run in an empty directory"
    fi
fi

cat <<'EOF'
Welcome to oss-stats!

We'll go ahead and setup this directory to be ready to track your open source
stats!

EOF

do_gem
debug "OSS_STATS_PATH is $OSS_STATS_PATH"
do_directories
do_files
do_config_files
do_gh_workflows
do_instructions
