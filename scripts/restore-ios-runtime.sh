#!/bin/zsh
# Restore a previously verified signed delivery after an intrusive device UI test.
set -eu
cd "${0:A:h:h}"
: "${MIKA_IOS_UDID:?Set the intended physical iPhone UDID}"
RECOVERY_DIR="${MIKA_RUNTIME_RECOVERY_DIR:-$PWD/.local/verified-ios-runtime}"
for artifact in MikaIOS.app LocalControlRunner-Runner.app mika-pair-export; do
  [[ -e "$RECOVERY_DIR/$artifact" ]] || { print -u2 "Verified recovery artifact missing: $artifact"; exit 1; }
done
codesign --verify --deep --strict "$RECOVERY_DIR/MikaIOS.app"
codesign --verify --deep --strict "$RECOVERY_DIR/LocalControlRunner-Runner.app"
python3 - "$RECOVERY_DIR" <<'PY'
import datetime,pathlib,plistlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
for name in ('MikaIOS.app','LocalControlRunner-Runner.app'):
    profile=subprocess.check_output(['security','cms','-D','-i',str(root/name/'embedded.mobileprovision')],stderr=subprocess.DEVNULL)
    expiry=plistlib.loads(profile)['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
    if expiry <= datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=30):
        sys.exit(f'Recovery signing expires too soon: {name}. Rebuild and verify the runtime first.')
if not (root/'mika-pair-export').stat().st_mode & 0o111:
    sys.exit('Recovery provisioning helper is not executable.')
PY
[[ "${1:-}" != --check ]] || exit 0
mkdir -p .local
chmod 700 .local
xcrun devicectl device info apps --device "$MIKA_IOS_UDID" --json-output .local/runtime-restore-apps.json -q
if python3 - <<'PY'
import json,sys
apps=json.load(open('.local/runtime-restore-apps.json'))['result']['apps']
sys.exit(0 if any(a.get('bundleIdentifier')=='com.huapohen.mikaremote.device-tests.xctrunner' for a in apps) else 1)
PY
then
  xcrun devicectl device uninstall app --device "$MIKA_IOS_UDID" com.huapohen.mikaremote.device-tests.xctrunner
fi
xcrun devicectl device install app --device "$MIKA_IOS_UDID" "$RECOVERY_DIR/MikaIOS.app"
xcrun devicectl device install app --device "$MIKA_IOS_UDID" "$RECOVERY_DIR/LocalControlRunner-Runner.app"
RESTORE_TMP="$(mktemp -d "$PWD/.local/runtime-restore.XXXXXX")"
PAIR_OUTPUT="$RESTORE_TMP/pairing.mobiledevicepairing"
trap 'rm -f "$PAIR_OUTPUT" "$RESTORE_TMP/status.json" "$RESTORE_TMP/pending.json"; rmdir "$RESTORE_TMP"' EXIT
"$RECOVERY_DIR/mika-pair-export" "$MIKA_IOS_UDID" "$PAIR_OUTPUT"
chmod 600 "$PAIR_OUTPUT"
xcrun devicectl device copy to --device "$MIKA_IOS_UDID" --source "$PAIR_OUTPUT" --destination Documents/LocalControlPairing.mobiledevicepairing --domain-type appDataContainer --domain-identifier com.huapohen.mikaremote -q
print '{"ready":false,"phase":"Recovery pending"}' > "$RESTORE_TMP/pending.json"
xcrun devicectl device copy to --device "$MIKA_IOS_UDID" --source "$RESTORE_TMP/pending.json" --destination Documents/LocalControlDiagnostics.json --domain-type appDataContainer --domain-identifier com.huapohen.mikaremote -q
RESTORE_RUN_ID="$(uuidgen)"
xcrun devicectl device process launch --device "$MIKA_IOS_UDID" --terminate-existing com.huapohen.mikaremote -- --mika-local-control-start --mika-control-run-id "$RESTORE_RUN_ID"
for attempt in {1..65}; do
  if xcrun devicectl device copy from --device "$MIKA_IOS_UDID" --source Documents/LocalControlDiagnostics.json --destination "$RESTORE_TMP/status.json" --domain-type appDataContainer --domain-identifier com.huapohen.mikaremote -q >/dev/null 2>&1; then
    state="$(python3 - "$RESTORE_TMP/status.json" "$RESTORE_RUN_ID" <<'PY'
import json,sys
try:
    value=json.load(open(sys.argv[1]))
    if value.get('launch_id') != sys.argv[2]: print('pending')
    elif value.get('ready') is True and value.get('requested') is True: print('ready')
    elif value.get('phase') in ('启动失败','配置无效','需要配对','隧道未连接','连接超时'): print('failed')
    else: print('pending')
except (ValueError,OSError): print('pending')
PY
)"
    [[ "$state" != ready ]] || { print 'Phone control runtime restored and ready.'; exit 0; }
    [[ "$state" != failed ]] || { print -u2 'Phone control restoration failed. Check LocalDevVPN, unlock state and signing; device is not ready.'; exit 1; }
  fi
  sleep 2
done
print -u2 'Phone control restoration timed out; device is not ready.'
exit 1
