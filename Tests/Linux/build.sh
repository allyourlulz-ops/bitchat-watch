#!/usr/bin/env bash
# Linux typecheck + test harness for the platform-independent code.
# Needs a Swift 6.x Linux toolchain. Env overrides:
#   SWIFT_BIN=/path/to/usr/bin   SYSROOT=/path/to/sysroot (only if libc headers aren't in /)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-/tmp/bitchat-watch-linux}"
SWIFT_BIN="${SWIFT_BIN:-$(dirname "$(command -v swiftc)")}"
SWIFTC="$SWIFT_BIN/swiftc"
CLANG="$SWIFT_BIN/clang"
SDKFLAGS=()
CFLAGS=()
if [[ -n "${SYSROOT:-}" ]]; then SDKFLAGS=(-sdk "$SYSROOT" -use-ld=lld); CFLAGS=(--sysroot="$SYSROOT"); fi
mkdir -p "$OUT"
if ! command -v ar >/dev/null 2>&1; then mkdir -p "$OUT/bin"; ln -sf "$SWIFT_BIN/llvm-ar" "$OUT/bin/ar"; export PATH="$OUT/bin:$PATH"; fi
MONO="$ROOT/MacTester/Vendor/Monocypher"

echo "== monocypher (C)"
"$CLANG" "${CFLAGS[@]}" -O2 -fPIC -c "$MONO/monocypher.c" -o "$OUT/monocypher.o"
"$CLANG" "${CFLAGS[@]}" -O2 -fPIC -I"$MONO" -c "$MONO/monocypher-ed25519.c" -o "$OUT/monocypher-ed25519.o"
"$SWIFT_BIN/llvm-ar" rcs "$OUT/libmonocypher.a" "$OUT/monocypher.o" "$OUT/monocypher-ed25519.o"

echo "== CryptoKit shim module (Linux only)"
"$SWIFTC" "${SDKFLAGS[@]}" -parse-as-library -emit-library -static -emit-module -module-name CryptoKit \
  -I "$HERE/CMonocypher" -L "$OUT" \
  "$HERE/CryptoKitShim/CryptoKit.swift" "$ROOT/MacTester/Sources/Core/PureSHA256.swift" \
  -emit-module-path "$OUT/CryptoKit.swiftmodule" -o "$OUT/libCryptoKit.a"

SHARED=$(find "$ROOT/Shared" -name '*.swift' | sort)
TESTER_CORE=$(find "$ROOT/MacTester/Sources/Core" -name '*.swift' | sort)
TESTS=$(find "$HERE/Tests" -name '*.swift' | sort)

echo "== shared + tester core + tests (swift 5 mode, one module)"
# shellcheck disable=SC2086
"$SWIFTC" "${SDKFLAGS[@]}" -swift-version 5 -O -module-name HarnessTests \
  -I "$OUT" -I "$HERE/CMonocypher" -L "$OUT" -lCryptoKit -lmonocypher \
  -D LINUX_HARNESS \
  $SHARED $TESTER_CORE $TESTS -o "$OUT/harness"

echo "== shared code typecheck in Swift 6 language mode (strict concurrency diagnostics)"
# shellcheck disable=SC2086
"$SWIFTC" "${SDKFLAGS[@]}" -swift-version 6 -typecheck -module-name Swift6Check \
  -I "$OUT" -I "$HERE/CMonocypher" $SHARED 2>"$OUT/swift6.log" && echo "swift6: clean" || { echo "swift6: diagnostics (see $OUT/swift6.log)"; grep -c "error:" "$OUT/swift6.log" || true; }

echo "== run"
"$OUT/harness" "$ROOT"
