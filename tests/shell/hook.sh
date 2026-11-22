#!/bin/sh
# Plain sh: no ERR trap, so the exit code is what is reported.
. "$(dirname "$0")/../../zharp.sh"
echo "working"
false
echo "never"
