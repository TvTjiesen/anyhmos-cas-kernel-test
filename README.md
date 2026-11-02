# cas 内核 × 鸿蒙 IPC 编译验证

## 这是什么

第 0 步可行性验证：把 **anyhmos（小米平板 6S Pro / 鸿蒙 7）的 `compat/ipc` 内核模块**，
放到 **小米 10 Ultra（cas）的 Linux 4.19.325 内核树**上尝试编译。

- 编译通过 → 鸿蒙的 binder/access_tokenid 接口可以在 4.19 上实现，移植项目继续
- 编译失败 → 按缺失符号评估 backport 成本，决定是否止损

**只编译，不接触任何设备。**

## 目录

```
hmos_ipc/                       # 从 anyhmos 复制（318 KB）
  binder.c                      # 204 KB，鸿蒙用 binder 实现（含 6.1 扩展）
  binder_alloc.c / .h
  binder_internal.h
  access_tokenid.c / .h
  ace5_tokens.c / .h
  private_api.c / .h
  hmos_config.h                 # 注明：Linux 6.1 Binder extension, local to this module on stock 5.15
  Makefile                      # obj-m += sheng_hmos_ipc.o
  dbitmap.h / binder_trace.h / sheng_hmos_api_v1.h
.github/workflows/kernel-test.yml
```

## 本地运行（需要 Linux 环境）

```sh
sudo apt install build-essential bc bison flex libssl-dev libelf-dev gcc-aarch64-linux-gnu
git clone --depth 1 -b lineage-23.2 https://github.com/LineageOS/android_kernel_xiaomi_sm8250.git ksrc
cd ksrc
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out vendor/kona_defconfig
scripts/kconfig/merge_config.sh -O out out/.config arch/arm64/configs/vendor/xiaomi/cas.config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out prepare modules_prepare -j$(nproc)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out \
  M=$PWD/../hmos_ipc KBUILD_MODPOST_WARN=1 modules -j$(nproc)
```

## 关键背景

| 项 | anyhmos（已成功机型） | cas |
|---|---|---|
| 内核 | 5.15.178 GKI | **4.19.325**（非 GKI） |
| binder 扩展 | 需要在模块内自带 6.1 扩展 | 未知，本次验证 |
| 分区 | boot/init_boot/vendor_boot | 只有 boot/dtbo/recovery |

## 预期风险

4.19 上最可能缺的东西：

1. `binder_alloc` 的新接口（5.x 多次重构）
2. `BINDER_GET_EXTENDED_ERROR`（6.1 引入，`hmos_config.h` 已有 `#ifndef` 兜底）
3. `task_struct` 字段、`struct file` 的 f_op 变化
4. `ashmem`（5.18 移除，5.x 需要逆移植；4.19 反而原生自带，对 cas 有利）
5. `memfd` / `pidfd` 相关能力