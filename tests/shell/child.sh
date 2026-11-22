#!/usr/bin/env bash
# Run under `zharp run` and sourcing the hook too: the error is reported once, by the hook.
source "$(dirname "$0")/../../zharp.sh"
cp /nonexistent-zharp-file /tmp/
