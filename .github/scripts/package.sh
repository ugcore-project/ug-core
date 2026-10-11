#!/usr/bin/env bash
# Builds the archive owners install: only what FXServer runs, checked against the manifest.
#
#   bash .github/scripts/package.sh <version> <output folder>
#
# Writes <output>/ug-core/ (the unpacked resource), <output>/ug-core-<version>.zip and its .sha256.
# Run from the repository root. LUA selects the Lua 5.4 binary, lua5.4 by default. ARCHIVE names the zip.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: package.sh <version> <output folder>" >&2
  exit 2
fi

version=$1
output=$2
stage="$output/ug-core"
lua=${LUA:-lua5.4}

# A list of what ships, not of what stays out: a new top-level file never leaks into releases by accident.
SHIPPED=(fxmanifest.lua import.lua import core modules locales LICENSE README.md CHANGELOG.md)

rm -rf "$stage"
mkdir -p "$stage"

for path in "${SHIPPED[@]}"; do
  if [ -e "$path" ]; then
    cp -R "$path" "$stage/"
  elif [ "$path" != CHANGELOG.md ]; then
    echo "package: $path is missing" >&2
    exit 1
  fi
done

# Folder placeholders are for git only. config/ gets its own back: it ships empty, so extracting an
# update over an installed copy keeps every owner file.
find "$stage" -name .gitkeep -type f -delete
mkdir -p "$stage/config"
: > "$stage/config/.gitkeep"

# The manifest version becomes the build's version. Line endings stay as they are.
perl -pi -e "s/^version '[^']*'[^\r\n]*/version '${version}'/" "$stage/fxmanifest.lua"

if ! grep -q "^version '${version}'" "$stage/fxmanifest.lua"; then
  echo "package: could not set the manifest version to ${version}" >&2
  exit 1
fi

# pwd -W gives a Windows path in Git Bash, for a Windows Lua binary. Elsewhere it fails and pwd answers.
check="$(pwd -W 2>/dev/null || pwd)/.github/scripts/check-repository.lua"

(cd "$stage" && find . -type f | sort | "$lua" "$check" --package)

# ARCHIVE overrides the name, such as a stable ug-core-dev.zip for the rolling dev build.
archive=${ARCHIVE:-ug-core-${version}.zip}

rm -f "$output/$archive" "$output/$archive.sha256"
(cd "$output" && zip -qrX "$archive" ug-core && sha256sum "$archive" > "$archive.sha256")

echo "Packaged $output/$archive"
