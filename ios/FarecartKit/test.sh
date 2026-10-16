#!/bin/sh
# Runs the FarecartKit tests. Works on a Mac with only Command Line Tools installed:
# CLT ships the Swift Testing macro plugin outside the default search path, so we point at it.
# Inside Xcode (or with a full Xcode toolchain selected) plain `swift test` works.
set -e
cd "$(dirname "$0")"
PLUGINS="$(xcrun --find swift 2>/dev/null | sed 's|/usr/bin/swift$||')/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  exec swift test "$@"
fi
