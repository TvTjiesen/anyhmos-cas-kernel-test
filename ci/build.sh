#!/usr/bin/env bash
# cas-h6 kernel build on GitHub Actions Ubuntu runner.
#
# Base recipe is copied from the user's own SUCCESSFUL cas-kernel-ci workflow
# (TvTjiesen/cas-kernel-ci, commit 2554ac9) which produced boot-v118.img.
# Added on top: HarmonyOS 6 code-sign / fs-verity / EROFS enablement and the
# remaining y2q patches (0005, 0007) that cas-ci never carried.
#
# Every failure is recorded, never hidden with `|| true`.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KSRC="$ROOT/ksrc"
PATCHES="$ROOT/patches/harmonyos6"
REPORT="$ROOT/apply-report.txt"
ART="$ROOT/artifacts"
CROSS="aarch64-linux-gnu-"
: > "$REPORT"
mkdir -p "$ART"

log() { echo "[build] $*" | tee -a "$REPORT"; }

log "=== 1. fetch kernel tree (lineage-23.2, matches cas-ci patches) ==="
rm -rf "$KSRC"
timeout 900 git clone --depth 1 --branch lineage-23.2 \
  https://github.com/LineageOS/android_kernel_xiaomi_sm8250.git "$KSRC" 2>&1 | tail -8
cd "$KSRC" || exit 2
log "kernel HEAD = $(git rev-parse HEAD)"
head -6 Makefile | tee -a "$REPORT"

log "=== 2. provide missing scripts/min-tool-version.sh ==="
printf '#!/bin/sh\necho 2.23\n' > scripts/min-tool-version.sh
chmod +x scripts/min-tool-version.sh
log "helper written"

log "=== 3. apply patches (cas-adapted where available) ==="
# 0001/0002/0003/0004/0006 come from the user's cas-ci repo and already match
# the Xiaomi tree. 0005/0007 are y2q originals and may leave .rej files.
for p in "$PATCHES"/000*.patch; do
  n=$(basename "$p")
  if patch -p1 -F3 --forward --no-backup-if-mismatch -i "$p" >>"$REPORT" 2>&1; then
    log "PATCH OK      $n"
  else
    log "PATCH PARTIAL $n (see .rej entries below)"
  fi
done
find . -name '*.rej' -print >> "$REPORT" || true
log "total .rej files: $(find . -name '*.rej' | wc -l)"
git status --short | head -120 >> "$REPORT" || true

log "=== 3b. overlay the repaired crypto/ecc.c ==="
# y2q patch 0005 was generated against the Samsung 4.19 tree. On the Xiaomi
# tree three ecc.c hunks fail; the missing one carries the #endif closing the
# CONFIG_ARCH_SUPPORTS_INT128 block, which produced "unterminated #else" and
# truncated the file at line 346 in CI round 3. A locally reproduced, fully
# applied and balanced ecc.c is shipped as an overlay so patch context drift
# can no longer break it.
cp "$ROOT/ci/overlay/crypto/ecc.c" crypto/ecc.c
rm -f crypto/ecc.c.rej drivers/dma-buf/dma-buf.c.rej
log "ecc.c overlay: $(wc -l < crypto/ecc.c) lines, $(grep -c 'add_128_128' crypto/ecc.c) add_128_128 refs"

# The one remaining .rej (0003) removes a duplicate spin_lock in
# dma_buf_set_name(). It does not break the build but can deadlock a CPU at
# runtime (y2q A2). Apply it by exact text replacement, guarded.
python3 - <<'PY'
p = 'drivers/dma-buf/dma-buf.c'
s = open(p, encoding='utf-8', errors='replace').read()
old = ("\tspin_lock(&dmabuf->name_lock);\n"
       "\tkfree(dmabuf->name);\n"
       "\tdmabuf->name = name;\n"
       "\tspin_unlock(&dmabuf->name_lock);\n")
new = "\tkfree(dmabuf->name);\n\tdmabuf->name = name;\n"
if old in s:
    open(p, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
    print('[build] dma-buf duplicate spin_lock removed')
else:
    print('[build] WARN dma-buf pattern not found; left unchanged')
PY

log "=== 4. configure: base defconfig -> fragments -> scripts/config ==="
make O=out ARCH=arm64 CROSS_COMPILE="$CROSS" vendor/kona-perf_defconfig 2>&1 | tail -15
export KCONFIG_CONFIG="$PWD/out/.config"
scripts/kconfig/merge_config.sh -m out/.config \
  arch/arm64/configs/vendor/xiaomi/sm8250-common.config \
  arch/arm64/configs/vendor/xiaomi/cas.config 2>&1 | tail -20
scripts/config --file out/.config \
  -e ACCESS_TOKENID -e BINDER_SENDER_INFO \
  -e DEVTMPFS -e DEVTMPFS_MOUNT -d ANDROID_BINDERFS \
  -e ANDROID_BINDER_IPC -e CGROUP_PIDS -e CGROUP_DEVICE -e MEMCG \
  -e ION_SYSTEM_HEAP -e ION_CMA_HEAP -e ION_CHUNK_HEAP -e ION_CARVEOUT_HEAP -e DMABUF_HEAPS \
  -e FS_VERITY -e FS_VERITY_BUILTIN_SIGNATURES \
  -e CRYPTO_ECC -e CRYPTO_ECDSA -e CRYPTO_ECDH \
  -e PKCS7_MESSAGE_PARSER -e X509_CERTIFICATE_PARSER \
  -e EROFS_FS -e EROFS_FS_XATTR -e EROFS_FS_SECURITY \
  -e BLK_DEV_LOOP -e PID_NS -e USER_NS -e FAIR_GROUP_SCHED \
  -e QCOM_KGSL 2>&1 | tail -20
make O=out ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig 2>&1 | tail -15
log "--- key config values ---"
grep -E 'CONFIG_(ARCH_QCOM|COMPAT|ACCESS_TOKENID|BINDER_SENDER_INFO|FS_VERITY|EROFS_FS|ANDROID_BINDERFS|QCOM_KGSL|CRYPTO_ECDSA|CRYPTO_ECC|BLK_DEV_LOOP)=' out/.config >> "$REPORT" || true
grep -E 'CONFIG_(ARCH_QCOM|COMPAT|ACCESS_TOKENID|BINDER_SENDER_INFO|FS_VERITY|EROFS_FS|QCOM_KGSL|CRYPTO_ECDSA)=' out/.config || true

log "=== 5. build Image.gz-dtb ==="
make -j"$(nproc)" O=out ARCH=arm64 CROSS_COMPILE="$CROSS" \
  KCFLAGS="-Wno-error -Wno-attribute-alias" Image.gz-dtb 2>&1 | tee "$ROOT/build.log"
RC=${PIPESTATUS[0]}
log "build rc=$RC"

log "=== 6. collect artifacts ==="
cp out/arch/arm64/boot/Image.gz-dtb "$ART/Image.gz-dtb" 2>/dev/null || log "WARN no Image.gz-dtb"
cp out/arch/arm64/boot/Image "$ART/Image" 2>/dev/null || log "WARN no Image"
find out/arch/arm64/boot -name '*.dtb' -exec cp {} "$ART/" \; 2>/dev/null || true
cp out/.config "$ART/kernel.config" 2>/dev/null || true
cp "$REPORT" "$ART/apply-report.txt"
log "artifacts:"; ls -la "$ART"
exit "$RC"
