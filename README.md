# cas-h6 kernel CI

Compiles the Xiaomi Mi 10 Ultra (`cas`, SM8250) 4.19.325 kernel with the seven
HarmonyOS 6 enablement patches proven on the Samsung SM-G986N (`y2q`) — same
SoC, same Adreno 650, same 4.19 kernel generation.

Why this exists: the local Windows machine has no WSL / Docker / make / clang,
so the kernel is built on a GitHub Actions Ubuntu runner instead. Installing
WSL would require a system reboot and was deliberately avoided.

## What it does

1. Fetches `LineageOS/android_kernel_xiaomi_sm8250` at the exact local baseline
   `71b13e62f057a649b77fe4062feb73ee72ad609c` (falls back to `lineage-23.2`).
2. Adds a shim for `scripts/min-tool-version.sh` — the reason the earlier CI
   attempt died at `vendor/kona_defconfig` with "assembler is not supported".
3. Applies `patches/harmonyos6/0001…0007`:
   - `0001` access-token + Binder ioctl 30/31/32 + sender PID
   - `0002` C89 declaration placement
   - `0003` dma-buf double lock
   - `0004` DRM master for native display UIDs
   - `0005` ECDSA / PKCS#7 / code-sign / fs-verity backport (the big one)
   - `0006` msm GEM cache flush (fixes 64-byte black lines)
   - `0007` `/proc/dsmm/developer`
   Patch mode is recorded in `apply-report.txt`: `APPLY OK`, `APPLY 3WAY`, or
   `APPLY FAIL` with `.rej` paths. **The first run is expected to need patch
   context adaptation** — the patches were generated against the Samsung
   sm8250 tree, not the Xiaomi one.
4. Merges `vendor/kona_defconfig` + `vendor/xiaomi/cas.config` + `ci/h6.config`.
5. Builds `Image` + `dtbs`, uploads `artifacts/` and `build.log`.

## This workflow never touches a device

It only compiles. Flashing, booting and debugging all happen locally under
`E:\harmony7\cas-h6\ROADMAP.md` with explicit stage gates and rollback.

## Trigger

```sh
gh workflow run cas-h6-kernel.yml --ref cas-h6 --repo TvTjiesen/anyhmos-cas-kernel-test
gh run list --workflow=cas-h6-kernel.yml --repo TvTjiesen/anyhmos-cas-kernel-test
gh run download <run-id> --repo TvTjiesen/anyhmos-cas-kernel-test
```

## Provenance

Patches copied verbatim from `Janlaywss/SM-G986N-Rom-Space` commit
`2c7cba4653228f4a7b680a4273bb633b6c884b6a` (GPL-2.0 / Apache-2.0 notices
retained in the patches). `ci/preinit_loop.c.reference` is the y2q PID1
watchdog skeleton, kept for reference only — it is not built here.
