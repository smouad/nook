#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")" && pwd)"
python3 "$plugin_dir/verify-upstream.py"
scratch_dir="$(mktemp -d /tmp/nook-mouse-build.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT # Generated compiler output only.
source "$plugin_dir/build-native.sh"
mkdir -p "$plugin_dir/bin"
for architecture in arm64 x86_64; do
  build_mouse_native "$architecture" "$scratch_dir/$architecture" "$scratch_dir/$architecture-objects" "$plugin_dir"/native/*.swift
done
xcrun lipo -create "$scratch_dir/arm64" "$scratch_dir/x86_64" -output "$plugin_dir/bin/helper"
codesign --force --sign - --identifier com.yusuf.nook.plugin.mouse "$plugin_dir/bin/helper"
echo 'Built universal Mouse helper (arm64 + x86_64). No helper was launched.'
