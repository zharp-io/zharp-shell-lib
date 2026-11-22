# bats with what the shell tests use: jq to read the payloads, zsh, curl, python3 and node for
# the programs `zharp run` wraps.
FROM bats/bats:1.11.0
RUN apk add --no-cache jq zsh curl python3 nodejs coreutils
