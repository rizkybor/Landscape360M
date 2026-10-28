#!/usr/bin/env bash
# Regenerates test/fixtures/web_reference.json from the web app's TypeScript, so the Dart
# parity tests compare against the web's real output.
# Usage: WEB_REPO=../Landscape360 tool/web_reference/generate.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
web="$(cd "${WEB_REPO:-$root/../Landscape360}" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed "s#'WEB/#'$web/#" "$here/gen.ts" > "$tmp/gen.ts"
NODE_PATH="$web/node_modules" "$web/node_modules/.bin/esbuild" "$tmp/gen.ts" --bundle --platform=node \
  --format=cjs --outfile="$tmp/gen.cjs" --log-level=warning --tsconfig="$web/tsconfig.app.json"
node "$tmp/gen.cjs" > "$root/test/fixtures/web_reference.json"
echo "Wrote test/fixtures/web_reference.json"
