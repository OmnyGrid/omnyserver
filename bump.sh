#!/bin/bash
# Bump the package version, keeping lib/src/version.dart in sync with
# pubspec.yaml, and publish. Requires `dart pub global activate dart_bump`.
#
# Usage: ./bump.sh <PUB_DEV_API_KEY> [patch|minor|major]

APIKEY=$1
shift  # remove the API key from "$@"

dart_bump . \
  --extra-file "lib/src/version.dart=omnyServerVersion\\s*=\\s*['\"](.*)['\"]" \
  --api-key $APIKEY \
  "$@"
