#!/bin/bash

if [ -z "$1" ]; then
    mapfile -t files < <(find . -type f -name \*.sh)
    exec shellcheck "${files[@]}"
fi

exec shellcheck "${@}"
