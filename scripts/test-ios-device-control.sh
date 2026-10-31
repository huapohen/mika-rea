#!/bin/zsh
set -eu
ROOT_DIR="${0:A:h:h}"
: "${MIKA_IOS_UDID:?Set MIKA_IOS_UDID to the paired iPhone UDID}"
cd "$ROOT_DIR"
RESTORE_REQUIRED=0
RECOVERY_DIR="${MIKA_RUNTIME_RECOVERY_DIR:-$ROOT_DIR/.local/verified-ios-runtime}"
mkdir -p .local
xcrun devicectl device info apps --device "$MIKA_IOS_UDID" --json-output .local/ui-test-installed-apps.json -q
if python3 - <<'PY'
import json,sys
apps=json.load(open('.local/ui-test-installed-apps.json'))['result']['apps']
sys.exit(0 if any(a.get('bundleIdentifier') in ('com.huapohen.mikaremote','com.huapohen.mikaremote.local-runner.xctrunner') for a in apps) else 1)
PY
then
  MIKA_RUNTIME_RECOVERY_DIR="$RECOVERY_DIR" scripts/restore-ios-runtime.sh --check
  finish() {
    local test_exit=$?
    trap - EXIT
    if [[ "$RESTORE_REQUIRED" == 1 ]]; then
      if ! MIKA_RUNTIME_RECOVERY_DIR="$RECOVERY_DIR" scripts/restore-ios-runtime.sh; then
        print -u2 "Runtime restoration failed; do not report this device as ready."
        exit 1
      fi
    fi
    exit "$test_exit"
  }
  trap finish EXIT
  trap 'exit 130' INT TERM
  RESTORE_REQUIRED=1
  xcrun devicectl device uninstall app --device "$MIKA_IOS_UDID" com.huapohen.mikaremote.local-runner.xctrunner
fi
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/MikaIOS.xcodeproj -scheme DeviceControl -destination "id=$MIKA_IOS_UDID" -derivedDataPath "${TMPDIR:-/tmp}/mika-device-control" -allowProvisioningUpdates "$@" test
