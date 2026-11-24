#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Ensuring aarch64-apple-ios Rust target is installed..."
rustup target add aarch64-apple-ios

echo "==> Building unstripped host interlude-ffi (debug) for UniFFI Swift bindgen..."
cargo build -p interlude-ffi --lib

echo "==> Building interlude-ffi for aarch64-apple-ios (release)..."
cargo build -p interlude-ffi --release --target aarch64-apple-ios

OUT_DIR="$REPO_ROOT/target/uniffi-ios"
HEADERS_DIR="$OUT_DIR/headers"
XCFRAMEWORK="$REPO_ROOT/ios/Vendor/InterludeCoreFFI.xcframework"
SWIFT_DEST="$REPO_ROOT/ios/Interlude/Generated"

rm -rf "$OUT_DIR" "$XCFRAMEWORK"
mkdir -p "$HEADERS_DIR" "$SWIFT_DEST"

echo "==> Generating UniFFI Swift bindings..."
cargo run -p interlude-ffi --features cli --bin uniffi-bindgen -- generate \
  --library "$REPO_ROOT/target/debug/libinterlude_ffi.dylib" \
  --language swift \
  --out-dir "$OUT_DIR"

cp "$OUT_DIR/interlude_ffi.swift" "$SWIFT_DEST/InterludeCoreFFI.swift"
cp "$OUT_DIR/interlude_ffiFFI.h" "$HEADERS_DIR/"
cp "$OUT_DIR/interlude_ffiFFI.modulemap" "$HEADERS_DIR/module.modulemap"

echo "==> Packaging InterludeCoreFFI.xcframework..."
xcodebuild -create-xcframework \
  -library "$REPO_ROOT/target/aarch64-apple-ios/release/libinterlude_ffi.a" \
  -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK"

echo "==> iOS interlude-core XCFramework and Swift bindings updated."
