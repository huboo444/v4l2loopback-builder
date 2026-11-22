# Android 15 GKI 6.6.50 v4l2loopback 零 Panic 自动化云端构建仓库

本仓库专为三星 Galaxy Tab S10+ (Exynos 1580 / Android 15 GKI 6.6.50 内核) 自动化构建 `v4l2loopback.ko` 虚拟摄像头驱动。

---

## 🎯 硬件与内核黄金基准 (KMI Baseline)
- **目标内核**：`Linux 6.6.50-android15-8-abX520XXS4AYG5-4k`
- **KMI 前缀**：`6.6.50-android15-8`
- **KCFI 强校验**：`CONFIG_CFI_CLANG=y` (开启)
- **核心模块锚点 CRC**：`module_layout = 0x4e276f37`
- **对齐编译器**：AOSP Clang 18 (`clang-r510928` / build 11368308)

---

## 🚀 如何在 GitHub Actions 一键构建

1. 在 GitHub 上新建一个仓库（例如命名为 `v4l2loopback-builder`，Public 或 Private 均可）。
2. 将本目录的所有文件推送到该仓库的主分支（`main`）：
   ```bash
   git remote add origin <你的GitHub仓库地址>
   git push -u origin main
   ```
3. 推送完成后，点击 GitHub 仓库页面的 **Actions** 标签：
   - 工作流 `Build v4l2loopback (Android 15 GKI 6.6.50)` 会自动启动运行！
   - 你也可以在 Actions 页面随时点击 **Run workflow** 手动触发。
4. 构建耗时约 5~8 分钟。构建成功后，在页面下方的 **Artifacts** 区域即可直接下载：
   - **`v4l2loopback-android15-gki66.zip`**
5. 解压出来的 `v4l2loopback.ko` 即是通过零 Panic ELF64 ABI 门禁的最终驱动！
