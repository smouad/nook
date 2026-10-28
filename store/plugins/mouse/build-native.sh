#!/bin/bash
# Shared native compilation for the helper and input-free engine tests.
build_mouse_native() {
  local architecture="$1" output="$2" scratch="$3"
  shift 3
  local target="$architecture-apple-macos14.2"
  local upstream="$plugin_dir/upstream"
  local smoothing="$upstream/Helper/Core/Smoothing"
  local includes=( -I "$upstream/adapter" -I "$smoothing" )
  mkdir -p "$scratch"
  xcrun swiftc -swift-version 5 -warnings-as-errors "${NOOK_MOUSE_SWIFT_OPTIMIZATION:--O}" -whole-module-optimization -parse-as-library \
    -target "$target" -module-name NookMouseEngine \
    -import-objc-header "$plugin_dir/native/NookMouse-Bridging.h" "${includes[@]}" \
    -emit-object -emit-module-path "$scratch/NookMouseEngine.swiftmodule" \
    -emit-objc-header -emit-objc-header-path "$scratch/Mac_Mouse_Fix_Helper-Swift.h" \
    "$@" "$upstream/Shared/Math/Math.swift" "$upstream"/Shared/Math/Curves/*.swift \
    "$upstream/Helper/Core/Buttons/ClickCycle.swift" \
    "$smoothing/RollingAverage.swift" "$smoothing/Smoother.swift" -o "$scratch/swift.o"
  local objects=( "$scratch/swift.o" )
  local source object
  for source in "$upstream/Helper/Core/Scroll/ScrollAnalyzer.m" "$smoothing/CircularBuffer.m" "$upstream/adapter/NookMMFAnalyzer.m"; do
    object="$scratch/$(basename "$source" .m).o"
    xcrun clang -fobjc-arc -fmodules -DNDEBUG -target "$target" "${includes[@]}" \
      -I "$scratch" -I "$upstream/Helper/Core/Scroll" -I "$upstream/Helper/Core/Config" \
      -c "$source" -o "$object"
    objects+=( "$object" )
  done
  xcrun swiftc -target "$target" "${objects[@]}" -framework Cocoa -framework QuartzCore -o "$output"
}
