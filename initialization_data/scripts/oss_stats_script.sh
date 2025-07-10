#!/bin/bash

oss_stats=$(bundle show oss-stats)
script="$1"
shift

exec "$oss_stats/scripts/$script" "$@"
