#!/usr/bin/env bash
# ZHARP_ERREXIT=false: the script's own error behaviour; only how it ends is reported.
source "$(dirname "$0")/../../zharp.sh"
cat /nonexistent-zharp-file
echo "went on"
