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

log "=== 3d. inject CASDBG diagnostics into lookup_bdev() ==="
# Decisive probe for the H6 mount-ENOENT mystery. On this kernel mount() returns
# ENOENT for EVERY block-device path (see reports/round-041..043), while the
# 4.19.157 recovery kernel mounts the same partition fine and open()/lstat()
# work. fs/block_dev.c:lookup_bdev() is the only site that can yield ENOENT
# (via kern_path); every other branch is ENOTBLK/EACCES/ENOMEM. Print them all
# so one boot names the exact failing branch instead of another guess.
python3 "$ROOT/ci/patch_lookup_bdev_dbg.py" 2>&1 | tee -a "$REPORT"
python3 "$ROOT/ci/patch_mount_dbg.py" 2>&1 | tee -a "$REPORT"
# round-044 showed lookup_bdev() is never reached, so do_mount()/do_new_mount()
# now carry their own prints to find which pre-step returns ENOENT.
if ! grep -q "CASDBG injected: 2 sites" "$REPORT" || \
   ! grep -q "CASDBG injected: 7 sites" "$REPORT"; then
  log "FATAL CASDBG injection incomplete (pattern drift?)"
  exit 3
fi
log "CASDBG armed: lookup_bdev + do_mount + do_new_mount"

log "=== 3c. bake a USB serial console into the kernel command line ==="
# `console=ttyGS0` is what fills gserial_cons.index; without it every gs port is
# rejected by gs_console_connect() ("port num [N] is not support console") and
# not one byte reaches the cable. The boot image header is deliberately NOT
# touched -- editing its cmdline made the cas bootloader answer "Load Error"
# twice -- so the token rides in the built-in cmdline instead.
# CONFIG_CMDLINE_EXTEND=y is already set in kona-perf_defconfig, so the built-in
# CONFIG_CMDLINE is appended to the bootloader cmdline by arm64 setup_arch. That
# is the config-only way to add a console token: no boot image header edit, no
# source pattern to miss. The token is added in the scripts/config stage below.

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
  -e QCOM_KGSL   -e U_SERIAL_CONSOLE -e USB_G_SERIAL -e USB_ACM -e USB_CONFIGFS_ACM   -e SECURITY_SELINUX_BOOTPARAM -e SECURITY_SELINUX_DISABLE   --set-str CMDLINE "cgroup_disable=pressure ramoops_memreserve=4M console=ttyGS0,115200 ignore_loglevel selinux=0 initcall_debug" 2>&1 | tail -20
log "=== 4b. enable the SDE/MDSS display stack ==="
# round-026: the running kernel has CONFIG_DRM_MSM unset, so cas' mdss@1c00000
# node has no driver at all -- zero msm_drm lines in kmsg, no /dev/dri/card0,
# no /sys/class/backlight/panel0-backlight. techpack/display/msm only builds
# via obj-$(CONFIG_DRM_MSM), so HarmonyOS' composer_host / render_service can
# never get a real screen. Nothing else in the recipe enabled it: neither
# kona-perf_defconfig nor sm8250-common.config nor cas.config mentions DRM_MSM.
scripts/config --file out/.config \
  -e DRM -e DRM_KMS_HELPER -e DRM_PANEL \
  -e DRM_MSM -e DRM_MSM_SDE -e DRM_MSM_DSI -e DRM_MSM_DP \
  -e QCOM_MDSS_PLL -e MSM_SDE_ROTATOR 2>&1 | tail -20

log "=== 4b2. keep legacy fbdev/fbcon OUT of the image ==="
# Round 6 booted to 3.18 s and then went silent for 28 s before preinit even
# reached its first line, then the board reset -- while run 9 (same kernel
# source, same patches) had PID1 up at 5.8 s. The only config delta between
# those two kernels is display: DRM_MSM, DRM_FBDEV_EMULATION and FB.
# CONFIG_FB=y drags in the whole ancient fbdev stack (FB_MSM, FB_SIMPLE,
# FB_VIRTUAL, LOGO, fbcon), and fbcon then tries to draw on a framebuffer that
# the SDE driver has not brought up yet. Android kernels never set CONFIG_FB;
# HarmonyOS' composer talks to /dev/dri/card0 through DRM atomic ioctls and has
# no use for fbdev. So: DRM only, no FB, no fbdev emulation, no logo.
scripts/config --file out/.config \
  -d FB -d DRM_FBDEV_EMULATION -d DRM_FBDEV_LEAK_PHYS_SMEM \
  -d LOGO -d FB_MSM -d FB_SIMPLE -d FB_VIRTUAL -d FB_KMS_HELPER 2>&1 | tail -20

log "=== 4b3. lockup detectors (a dead spin is currently invisible) ==="
# kona-perf_defconfig leaves CONFIG_SOFTLOCKUP_DETECTOR off, so a CPU stuck in
# a driver loop prints nothing at all before the board resets -- exactly what
# 6b and 6c look like. With the detectors on, the watchdog prints the stack of
# whatever is spinning, which beats guessing.
scripts/config --file out/.config \
  -e LOCKUP_DETECTOR -e SOFTLOCKUP_DETECTOR -e HARDLOCKUP_DETECTOR \
  -e DETECT_HUNG_TASK -e DEBUG_KERNEL 2>&1 | tail -20

log "=== 4c. drop the in-tree legacy msm driver (kona uses techpack SDE) ==="
# Enabling CONFIG_DRM_MSM also pulls in drivers/gpu/drm/msm, the *old*
# DPU1/MDP4/MDP5 HDMI/eDP driver. It is not what kona's mdss node binds to
# (cas' DT uses qcom,sde-kms, provided by techpack/display), and with gcc-12 it
# dies on msm_drv.c:1237 "control reaches end of non-void function
# [-Werror=return-type]" -- that is what failed run 15. LineageOS builds with
# clang (TARGET_KERNEL_NO_GCC), so they never see it. Empty the obj- rule:
# msm-y then has no consumer and none of those objects are compiled.
python3 - <<'PY' || { log "FATAL could not disable legacy drm/msm"; exit 3; }
p = 'drivers/gpu/drm/msm/Makefile'
s = open(p, encoding='utf-8').read()
old = 'obj-$(CONFIG_DRM_MSM)\t+= msm.o\n'
new = '# obj-$(CONFIG_DRM_MSM)\t+= msm.o  # legacy DPU1/MDP driver, not for kona\n'
if old not in s:
    print('[build] legacy obj rule not found, left unchanged')
    raise SystemExit(1)
open(p, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
print('[build] legacy drm/msm objects disabled')
PY

log "=== 4d. instrument the techpack display probe path ==="
# round 6b/6c both freeze the board: identical to run 9 for 3.18 s, then 28 s of
# total silence, preinit's first line at 31.8 s, hard reset at 32 s, no panic
# and no watchdog line (CONFIG_SOFTLOCKUP_DETECTOR is off in kona-perf, so a
# dead spin is invisible). Removing fbdev changed nothing, so the suspect is
# the techpack display driver itself. pr_err markers cost one round and turn
# "silence" into "the last stage we entered", which names the stuck call.
python3 - <<'PY' || { log "FATAL could not instrument techpack display"; exit 3; }
import re
p = 'techpack/display/msm/msm_drv.c'
s = open(p, encoding='utf-8').read()

def mark_before(anchor, tag):
    """Insert pr_err(tag) immediately before the line containing anchor."""
    global s
    i = s.find(anchor)
    if i < 0:
        print('[build] WARN anchor missing: ' + anchor)
        return
    ls = s.rfind('\n', 0, i) + 1
    indent = re.match(r'[ \t]*', s[ls:]).group(0)
    line = indent + 'pr_err("[CAS] ' + tag + '\\n");\n'
    s = s[:ls] + line + s[ls:]

mark_before('if (!modeset)', 'drm_register: enter')
mark_before('msm_smmu_driver_init();', 'drm_register: smmu_init')
mark_before('msm_dsi_register();', 'drm_register: dsi_register')
mark_before('msm_edp_register();', 'drm_register: edp_register')
mark_before('msm_hdmi_register();', 'drm_register: hdmi_register')
mark_before('return platform_driver_register(&msm_platform_driver);',
            'drm_register: pdev_register')
mark_before('ret = add_display_components(&pdev->dev, &match);',
            'pdev_probe: add_display_components')
mark_before('return component_master_add_with_match(&pdev->dev, &msm_drm_ops, match);',
            'pdev_probe: component_master_add')
mark_before('return msm_drm_init(dev, &msm_driver);', 'bind: msm_drm_bind')
mark_before('ddev = drm_dev_alloc(drv, dev);', 'init: drm_dev_alloc')
mark_before('ret = msm_mdss_init(ddev);', 'init: msm_mdss_init')
mark_before('ret = sde_power_resource_init(pdev, &priv->phandle);', 'init: sde_power_resource_init')
mark_before('ret = sde_dbg_init(&pdev->dev);', 'init: sde_dbg_init')
mark_before('ret = msm_component_bind_all(dev, ddev);', 'init: component_bind_all')
mark_before('kms = _msm_drm_init_helper(priv, ddev, dev, pdev);', 'init: _msm_drm_init_helper')
mark_before('ret = drm_irq_install(ddev, platform_get_irq(pdev, 0));', 'init: drm_irq_install')

n = s.count('pr_err("[CAS] ')
open(p, 'w', encoding='utf-8', newline='').write(s)
print('[build] instrumentation markers inserted: %d' % n)
PY

make O=out ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig 2>&1 | tail -15
log "--- display config after olddefconfig ---"
grep -E 'CONFIG_(DRM|DRM_MSM|DRM_MSM_SDE|DRM_MSM_DSI|DRM_MSM_DP|QCOM_MDSS_PLL|MSM_SDE_ROTATOR|DRM_FBDEV_EMULATION|DRM_PANEL)=' out/.config >> "$REPORT" || true
grep -E '^# CONFIG_DRM_MSM is not set' out/.config >> "$REPORT" || log "DRM_MSM is enabled"
grep -E '^CONFIG_FB=|^# CONFIG_FB is not set|^CONFIG_DRM_FBDEV_EMULATION=|^# CONFIG_DRM_FBDEV_EMULATION is not set' out/.config >> "$REPORT" || true
log "--- key config values ---"
grep -E 'CONFIG_(ARCH_QCOM|COMPAT|ACCESS_TOKENID|BINDER_SENDER_INFO|FS_VERITY|EROFS_FS|ANDROID_BINDERFS|QCOM_KGSL|CRYPTO_ECDSA|CRYPTO_ECC|BLK_DEV_LOOP)=' out/.config >> "$REPORT" || true
# USB gadget serial console: this is how the 6.7 s -> reset window becomes visible.
grep -E 'CONFIG_(U_SERIAL_CONSOLE|USB_G_SERIAL|USB_ACM|USB_CONFIGFS_ACM|USB_CONFIGFS)=' out/.config >> "$REPORT" || true
# The console token must survive olddefconfig; if it does not, the whole USB
# console channel is dead and every run is blind again.
{ grep -q 'console=ttyGS0' out/.config && log "CMDLINE token present: $(grep '^CONFIG_CMDLINE=' out/.config)"; } || log "WARN console=ttyGS0 MISSING from CONFIG_CMDLINE"
log "CMDLINE_EXTEND: $(grep '^CONFIG_CMDLINE_EXTEND=' out/.config)"
grep -E 'CONFIG_SECURITY_SELINUX_(BOOTPARAM|DISABLE)=' out/.config >> "$REPORT" || true 
grep -E 'CONFIG_(ARCH_QCOM|COMPAT|ACCESS_TOKENID|BINDER_SENDER_INFO|FS_VERITY|EROFS_FS|QCOM_KGSL|CRYPTO_ECDSA)=' out/.config || true

log "=== 5. build Image.gz-dtb ==="
make -j"$(nproc)" O=out ARCH=arm64 CROSS_COMPILE="$CROSS" \
  KCFLAGS="-Wno-error -Wno-error=return-type -Wno-error=maybe-uninitialized -Wno-error=implicit-fallthrough -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=unused-but-set-variable -Wno-attribute-alias" Image.gz-dtb 2>&1 | tee "$ROOT/build.log"
RC=${PIPESTATUS[0]}
log "build rc=$RC"
log "display objects: techpack/msm=$(ls out/techpack/display/msm/*.o 2>/dev/null | wc -l) drm/msm=$(ls out/drivers/gpu/drm/msm/*.o 2>/dev/null | wc -l)"
if [ "$RC" -ne 0 ]; then
  log "--- first build errors (full log in build.log artifact) ---"
  grep -E 'error:|Error [0-9]+|No such file or directory' "$ROOT/build.log" | head -40 >> "$REPORT" || true
fi

log "=== 6. collect experiment artifacts (BEFORE touching the config) ==="
cp out/arch/arm64/boot/Image.gz-dtb "$ART/Image.gz-dtb" 2>/dev/null || log "WARN no Image.gz-dtb"
cp out/arch/arm64/boot/Image "$ART/Image" 2>/dev/null || log "WARN no Image"
find out/arch/arm64/boot -name '*.dtb' -exec cp {} "$ART/" \; 2>/dev/null || true
cp out/.config "$ART/kernel.config" 2>/dev/null || true

log "=== 6b. build a GATEKEEPER kernel without a pstore console ==="
# Every H6 reset lands in the gatekeeper, which boots for ~2 s. A normal
# kernel registers a pstore console and overwrites the H6 kernel's last ~30 s
# of console -- the only record of why H6 rebooted. Disabling just
# CONFIG_PSTORE_CONSOLE makes the gatekeeper leave that reserved RAM alone.
# NOTE: the boot image header/cmdline are NOT modified. Editing the cmdline
# makes the cas bootloader reject the image with "Load Error" (proven twice).
scripts/config --file out/.config -d PSTORE_CONSOLE
make O=out ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig 2>&1 | tail -10
log "gatekeeper PSTORE_CONSOLE = $(grep -E '^CONFIG_PSTORE_CONSOLE=' out/.config || echo 'not set')"
cp out/.config "$ART/kernel-gatekeeper.config"
make -j"$(nproc)" O=out ARCH=arm64 CROSS_COMPILE="$CROSS" \
  KCFLAGS="-Wno-error -Wno-error=return-type -Wno-error=maybe-uninitialized -Wno-error=implicit-fallthrough -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=unused-but-set-variable -Wno-attribute-alias" Image 2>&1 | tee "$ROOT/build-gate.log"
GRC=${PIPESTATUS[0]}
log "gatekeeper build rc=$GRC"
if [ -f out/arch/arm64/boot/Image ]; then
  cp out/arch/arm64/boot/Image "$ART/Image-gatekeeper"
  log "Image-gatekeeper: $(stat -c %s "$ART/Image-gatekeeper") bytes"
else
  log "WARN no Image-gatekeeper"
fi
cp "$REPORT" "$ART/apply-report.txt"
log "artifacts:"; ls -la "$ART"
if [ "$RC" -ne 0 ] || [ "$GRC" -ne 0 ]; then exit 1; fi
exit 0
