#!/bin/zsh
# Compiles the platform-neutral core, the given format directories, and a main.swift into a macOS
# command-line tool, and runs it. For checking parsers outside of the app.
#
# Usage: Tools/run-parser.sh <output-binary> <main.swift> <Formats/Dir>... [-- <args for the tool>]
set -e
ROOT=${0:A:h:h}
OUT=$1; shift
MAIN=$1; shift
DIRS=()
while [[ $# -gt 0 && "$1" != "--" ]]; do DIRS+=("$ROOT/ModelViewer/Formats/$1"); shift; done
[[ "$1" == "--" ]] && shift
SOURCES=($ROOT/ModelViewer/Core/*.swift $ROOT/Tools/ModelInfo.swift)
for d in $DIRS; do SOURCES+=($d/**/*.swift(N)); done
xcrun swiftc -O -swift-version 6 -target arm64-apple-macosx15.0 -module-name ModelViewer -o "$OUT" "$MAIN" $SOURCES
"$OUT" "$@"
