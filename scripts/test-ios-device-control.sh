#!/bin/zsh
set -eu
ROOT_DIR="${0:A:h:h}"
: "${MIKA_IOS_UDID:?Set MIKA_IOS_UDID to the paired iPhone UDID}"
cd "$ROOT_DIR"
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/MikaIOS.xcodeproj -scheme DeviceControl -destination "id=$MIKA_IOS_UDID" -derivedDataPath "${TMPDIR:-/tmp}/mika-device-control" -allowProvisioningUpdates test
