#!/bin/zsh
set -eu
cd "${0:A:h:h}"
CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
RUSTUP_BIN="${RUSTUP_BIN:-$HOME/.cargo/bin/rustup}"
"$RUSTUP_BIN" target add aarch64-apple-ios
"$CARGO_BIN" build --locked --manifest-path ios/local-control/Cargo.toml --target aarch64-apple-ios --lib --release
mkdir -p ios/Native
cp ios/local-control/target/aarch64-apple-ios/release/libmika_local_control.a ios/Native/
case "${MIKA_IOS_VARIANT:-standard}" in
  standard) xcodegen generate --spec ios/project.yml ;;
  all-in-one)
    scripts/build-ios-proxy-core.sh
    xcodegen generate --spec ios/project.all-in-one.yml ;;
  *) print -u2 'MIKA_IOS_VARIANT must be standard or all-in-one'; exit 2 ;;
esac
