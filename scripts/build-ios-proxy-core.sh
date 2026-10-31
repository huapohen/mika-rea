#!/bin/zsh
set -eu
cd "${0:A:h:h}"
scripts/prepare-ios-proxy-core.sh
GO_BIN="${GO_BIN:-$(command -v go)}"
mkdir -p ios/Native
for MIKA_PLATFORM in iphoneos iphonesimulator; do
  MIKA_SDK="$(xcrun --sdk "$MIKA_PLATFORM" --show-sdk-path)"
  MIKA_CLANG="$(xcrun --sdk "$MIKA_PLATFORM" --find clang)"
  if [[ "$MIKA_PLATFORM" == iphoneos ]]; then
    MIKA_TARGET=arm64-apple-ios17.4
    MIKA_SUFFIX=device
  else
    MIKA_TARGET=arm64-apple-ios17.4-simulator
    MIKA_SUFFIX=sim
  fi
  GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$MIKA_CLANG" \
    CGO_CFLAGS="-isysroot $MIKA_SDK -target $MIKA_TARGET" \
    CGO_LDFLAGS="-isysroot $MIKA_SDK -target $MIKA_TARGET" \
    "$GO_BIN" -C ios/proxy-core build -mod=readonly -trimpath -buildmode=c-archive -ldflags='-s -w' -o "../Native/libmika_proxy_core_$MIKA_SUFFIX.a" .
done
