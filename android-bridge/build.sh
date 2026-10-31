#!/bin/zsh
set -eu
cd "${0:A:h}"
SDK_DIR="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
TOOLS="$SDK_DIR/build-tools/36.0.0"
mkdir -p build/classes build/dex
"$TOOLS/aapt2" link ${MIKA_BRIDGE_DEBUG:+--debug-mode} -o build/base.apk --manifest AndroidManifest.xml -I "$SDK_DIR/platforms/android-36/android.jar"
javac -source 8 -target 8 -cp "$SDK_DIR/platforms/android-36/android.jar" -d build/classes src/com/huapohen/mikabridge/*.java
jar cf build/classes.jar -C build/classes .
"$TOOLS/d8" --lib "$SDK_DIR/platforms/android-36/android.jar" --output build/dex build/classes.jar
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q ../unsigned.apk classes.dex)
"$TOOLS/zipalign" -f 4 build/unsigned.apk build/aligned.apk
if [ ! -f "$HOME/.android/debug.keystore" ]; then
 keytool -genkeypair -keystore "$HOME/.android/debug.keystore" -storepass android -alias androiddebugkey -keypass android -keyalg RSA -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'
fi
"$TOOLS/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out build/MikaBridge.apk build/aligned.apk
"$TOOLS/apksigner" verify build/MikaBridge.apk
