#!/bin/zsh
set -eu
cd "${0:A:h:h}"
MIHOMO_REV=3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8
MIHOMO_SOURCE="${MIKA_MIHOMO_SOURCE:-$PWD/.local/research/mihomo}"
# Choose and verify a working direct/proxy route before first fetching this source.
if [[ ! -d "$MIHOMO_SOURCE/.git" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/MetaCubeX/mihomo.git "$MIHOMO_SOURCE"
fi
git -C "$MIHOMO_SOURCE" cat-file -e "$MIHOMO_REV^{commit}" || git -C "$MIHOMO_SOURCE" fetch origin "$MIHOMO_REV"
mkdir -p .local/builddeps/mihomo
git -C "$MIHOMO_SOURCE" archive "$MIHOMO_REV" | tar -x -C .local/builddeps/mihomo
patch -p1 -d .local/builddeps/mihomo < patches/mihomo-packet-device.patch
