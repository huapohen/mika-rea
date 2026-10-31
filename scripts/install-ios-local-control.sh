#!/bin/zsh
# One-time cable provisioning. Runtime control remains on the phone.
set -eu
cd "${0:A:h:h}"
: "${MIKA_IOS_UDID:?Set MIKA_IOS_UDID to the intended, trusted physical iPhone}"
CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
TEAM_ID="${MIKA_TEAM_ID:-RQHK3ZN3W7}"
DERIVED_DIR="${TMPDIR:-/tmp}/mika-local-control-install"
mkdir -p .local
scripts/build-ios-local-control.sh
xcodebuild -project ios/MikaIOS.xcodeproj -scheme LocalControl -destination "id=$MIKA_IOS_UDID" -derivedDataPath "$DERIVED_DIR" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" build-for-testing
xcrun devicectl device install app --device "$MIKA_IOS_UDID" "$DERIVED_DIR/Build/Products/Debug-iphoneos/MikaIOS.app"
# The former UI-test runner is our own disposable build artifact. Free accounts
# allow only three installed development apps; remove only this superseded runner.
xcrun devicectl device info apps --device "$MIKA_IOS_UDID" --json-output .local/installed-before-local-control.json >/dev/null
if python3 - <<'CHECK'
import json,sys
apps=json.load(open('.local/installed-before-local-control.json'))['result']['apps']
sys.exit(0 if any(x.get('bundleIdentifier')=='com.huapohen.mikaremote.device-tests.xctrunner' for x in apps) else 1)
CHECK
then
  xcrun devicectl device uninstall app --device "$MIKA_IOS_UDID" com.huapohen.mikaremote.device-tests.xctrunner
fi
xcrun devicectl device install app --device "$MIKA_IOS_UDID" "$DERIVED_DIR/Build/Products/Debug-iphoneos/LocalControlRunner-Runner.app"
mkdir -p .local
PAIR_OUTPUT=".local/local-control-pairing-$(date +%s).mobiledevicepairing"
"$CARGO_BIN" run --locked --manifest-path ios/local-control/Cargo.toml --bin mika-pair-export -- "$MIKA_IOS_UDID" "$PAIR_OUTPUT"
xcrun devicectl device copy to --device "$MIKA_IOS_UDID" --source "$PAIR_OUTPUT" --destination Documents/LocalControlPairing.mobiledevicepairing --domain-type appDataContainer --domain-identifier com.huapohen.mikaremote -q
rm "$PAIR_OUTPUT"
xcrun devicectl device info apps --device "$MIKA_IOS_UDID" --include-all-apps --json-output .local/local-control-apps.json >/dev/null
python3 - <<'PY'
import json,os
apps=json.load(open('.local/local-control-apps.json'))['result']['apps']
catalog=[{'name':item['name'],'bundle_id':item['bundleIdentifier']} for item in apps if not item.get('hidden') and item.get('bundleIdentifier')]
fd=os.open('.local/LocalAppCatalog.json',os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as out:json.dump(catalog,out,ensure_ascii=False)
PY
xcrun devicectl device copy to --device "$MIKA_IOS_UDID" --source .local/LocalAppCatalog.json --destination Documents/LocalAppCatalog.json --domain-type appDataContainer --domain-identifier com.huapohen.mikaremote -q
xcrun devicectl device process launch --device "$MIKA_IOS_UDID" --terminate-existing com.huapohen.mikaremote
