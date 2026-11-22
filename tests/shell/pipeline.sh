#!/usr/bin/env bash
# A failing command in the middle of a pipeline: pipefail makes it the script's failure.
source "$(dirname "$0")/../../zharp.sh"
echo "start"
grep needle /dev/null | sort
echo "never"
