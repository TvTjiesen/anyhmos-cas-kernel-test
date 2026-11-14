#!/usr/bin/env bash
# cas-h6 kernel build on GitHub Actions Ubuntu runner.
# Fetches the exact cas kernel tree, applies the 7 HarmonyOS 6 enablement
# patches from the y2q port, merges the H6 config, builds Image + dtbs.
# Every failure is recorded instead of being hidden with `|| true`.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KSRC="$ROOT/ksrc"
PATCHES="$ROOT/patches/harmonyos6"
REPORT="$ROOT/apply-report.txt"
ART="$ROOT/artifacts"
KERNEL_COMMIT="71b13e62f057a649b77fe4062feb73ee72ad609c"
CROSS="aarch64-linux-gnu-"
: > "$REPORT"
mkdir -p "$ART"

log() { echo "[build] $*" | tee -a "$REPORT"; }

log "=== 1. fetch kernel tree ==="
mkdir -p "$KSRC"
cd "$KSRC" || exit 2
git init -q
git remote add origin https://github.com/LineageOS/android_kernel_xiaomi_sm8250.git
if timeout 900 git fetch --depth 1 origin "$KERNEL_COMMIT" 2>&1 | tail -5; then
  git checkout -q FETCH_HEAD
  log "pinned commit fetch OK"
else
  log "WARN pinned commit fetch failed; falling back to lineage-23.2 branch"
  timeout 900 git fetch --depth 1 origin lineage-23.2 2>&1 | tail -5 || exit 3
  git checkout -q FETCH_HEAD
fi
log "kernel HEAD = $(git rev-parse HEAD)"
head -6 Makefile | tee -a "$REPORT"

log "=== 2. work around missing scripts/min-tool-version.sh ==="
if [ ! -f scripts/min-tool-version.sh ]; then
  cat > scripts/min-tool-version.sh <<'EOF'
#!/bin/sh
# Minimal shim: this 4.19 tree calls as-version.sh but ships no helper.
case "$1" in
  gcc) echo 4.9 ;;
  binutils) echo 2.23 ;;
  llvm) echo 0 ;;
  *) echo 0 ;;
esac
EOF
  chmod +x scripts/min-tool-version.sh
  log "created min-tool-version shim"
fi

log "=== 3. apply HarmonyOS 6 patches (context tolerant) ==="
# These patches were generated against the Samsung sm8250 tree. Their index
# lines reference Samsung blobs that do not exist in the Xiaomi tree, so
# `git apply --3way` can NEVER succeed here. GNU patch with fuzz tolerates
# the remaining line-number / context drift. Failed hunks land in *.rej and
# are reported rather than hidden.
for p in "$PATCHES"/000*.patch; do
  n=$(basename "$p")
  if patch -p1 --forward --batch --fuzz=3 -i "$p" >>"$REPORT" 2>&1; then
    log "PATCH OK      $n"
  else
    log "PATCH PARTIAL $n (see .rej entries below)"
  fi
done
find . -name '*.rej' -print >> "$REPORT" || true
log "total .rej files: $(find . -name '*.rej' | wc -l)"
git status --short | head -120 >> "$REPORT" || true

log "=== 4. merge config (QCOM 4.19 fragment chain) ==="
CFG=arch/arm64/configs/vendor
mkdir -p out
# kona_defconfig alone leaves ARCH_QCOM=n and breaks compat_uptr_t.
# LineageOS sm8250 builds chain the perf defconfig + vendor device fragments.
scripts/kconfig/merge_config.sh -O out \
  "$CFG/kona-perf_defconfig" \
  "$CFG/debugfs.config" \
  "$CFG/xiaomi/sm8250-common.config" \
  "$CFG/xiaomi/cas.config" \
  "$ROOT/ci/h6.config" 2>&1 | tail -40
make ARCH=arm64 CROSS_COMPILE="$CROSS" O=out olddefconfig 2>&1 | tail -25
log "--- key config values ---"
grep -E 'CONFIG_(ARCH_QCOM|COMPAT|ACCESS_TOKENID|BINDER_SENDER_INFO|FS_VERITY|EROFS_FS|ANDROID_BINDERFS|QCOM_KGSL|CRYPTO_ECDSA|CRYPTO_ECC|BLK_DEV_LOOP)=' out/.config >> "$REPORT" || true
grep -E 'CONFIG_(ARCH_QCOM|COMPAT|ACCESS_TOKENID|BINDER_SENDER_INFO|FS_VERITY|EROFS_FS|QCOM_KGSL|CRYPTO_ECDSA)=' out/.config || true

log "=== 5. build Image + dtbs ==="
make ARCH=arm64 CROSS_COMPILE="$CROSS" O=out -j"$(nproc)" Image dtbs 2>&1 | tee "$ROOT/build.log"
RC=${PIPESTATUS[0]}
log "build rc=$RC"

log "=== 6. collect artifacts ==="
cp out/arch/arm64/boot/Image "$ART/Image" 2>/dev/null || log "WARN no Image produced"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cp {} "$ART/" \; 2>/dev/null || true
cp out/.config "$ART/kernel.config" 2>/dev/null || true
cp "$REPORT" "$ART/apply-report.txt"
log "artifacts:"; ls -la "$ART"
exit "$RC"
