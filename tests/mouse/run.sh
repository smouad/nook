#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mouse_test_dir=$(mktemp -d /tmp/nook-mouse-tests.XXXXXX)
trap 'rm -rf "$mouse_test_dir"' EXIT
plugin_dir="$PWD/store/plugins/mouse"
python3 "$plugin_dir/verify-upstream.py"
source "$plugin_dir/build-native.sh"
export NOOK_MOUSE_SWIFT_OPTIMIZATION=-Onone
native_sources=()
for native_source in "$plugin_dir"/native/*.swift; do
  [[ "$(basename "$native_source")" == main.swift ]] || native_sources+=( "$native_source" )
done
build_mouse_native "$(uname -m)" "$mouse_test_dir/native" "$mouse_test_dir/objects" \
  Nook/Core/SyntheticInput.swift "${native_sources[@]}" \
  Nook/Core/HotkeyMonitor.swift Nook/Core/ShortcutGesture.swift \
  tests/mouse/*.swift
"$mouse_test_dir/native"
node --check store/plugins/mouse/main.js
npm install --prefix "$mouse_test_dir" --no-save --package-lock=false --silent jsdom@26.1.0
cp tests/mouse/plugin.cjs "$mouse_test_dir/plugin.cjs"
node "$mouse_test_dir/plugin.cjs" "$PWD/store/plugins/mouse"
