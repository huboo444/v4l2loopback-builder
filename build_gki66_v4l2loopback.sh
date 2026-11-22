#!/usr/bin/env bash
# File (x86_64 Linux Build Host / WSL2 / GitHub Actions): build_gki66_v4l2loopback.sh
# 版本：v2.0 (精准适配 Exynos 1580 GKI 6.6.50 + KCFI=True + module_layout=0x4e276f37)
# 前置输入文件（置于当前工作目录）：
#   1. ./device_config.gz     (平板 /proc/config.gz)
#   2. ./kmi_baseline.json    (平板 verify_ko_abi.py extract 产出)
#   3. ./verify_ko_abi.py     (ELF ABI 门禁脚本)
set -euo pipefail

WORKDIR="$(pwd)/gki66_v4l2_build"
CLANG_DIR="${WORKDIR}/clang-r510928"
KERNEL_DIR="${WORKDIR}/common"
V4L2_DIR="${WORKDIR}/v4l2loopback"

# 严格对齐平板运行内核 uname -r 尾缀与黄金锚点 CRC
TARGET_SUFFIX="${TARGET_SUFFIX:--android15-8-abX520XXS4AYG5-4k}"
EXPECTED_LAYOUT_CRC="${EXPECTED_LAYOUT_CRC:-0x4e276f37}"
KERNEL_BRANCH="${KERNEL_BRANCH:-android15-6.6-2024-10_r1}"

for req in device_config.gz kmi_baseline.json verify_ko_abi.py; do
    [[ -f "$req" ]] || { echo "[ERROR] 缺失必要输入文件: $req" >&2; exit 1; }
done
[[ "$(uname -m)" == "x86_64" ]] || { echo "[ERROR] AOSP Clang r510928 仅支持 x86_64 Linux 宿主机" >&2; exit 1; }

mkdir -p "$WORKDIR"

# 1. 下载精确对齐的 AOSP Clang 18 (clang-r510928 / build 11368308)
if [[ ! -x "${CLANG_DIR}/bin/clang" ]]; then
    echo "=== [1/6] 下载 AOSP Clang 18 (clang-r510928) via git sparse-checkout ==="
    CLANG_REPO="${WORKDIR}/clang_repo"
    rm -rf "$CLANG_REPO" "$CLANG_DIR"
    git clone --depth=1 --filter=blob:none --no-checkout \
        https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
        "$CLANG_REPO"
    (
        cd "$CLANG_REPO"
        git sparse-checkout init --cone
        git sparse-checkout set clang-r510928
        git checkout
    )
    ls -la "$CLANG_REPO"
    mv "${CLANG_REPO}/clang-r510928" "$CLANG_DIR"
    rm -rf "$CLANG_REPO"
fi

export PATH="${CLANG_DIR}/bin:${PATH}"
clang --version | head -n 2

# 2. 拉取 android15-6.6 源码并验证精确 6.6.50 基线
if [[ ! -d "${KERNEL_DIR}/.git" ]]; then
    echo "=== [2/6] 拉取 AOSP GKI 内核源码 (branch=${KERNEL_BRANCH}) ==="
    git clone --depth=1 -b "$KERNEL_BRANCH" \
        https://android.googlesource.com/kernel/common "$KERNEL_DIR"
fi

KVER_MAJ=$(awk '/^VERSION =/{print $3; exit}' "${KERNEL_DIR}/Makefile")
KVER_PAT=$(awk '/^PATCHLEVEL =/{print $3; exit}' "${KERNEL_DIR}/Makefile")
KVER_SUB=$(awk '/^SUBLEVEL =/{print $3; exit}' "${KERNEL_DIR}/Makefile")
KVER_FULL="${KVER_MAJ}.${KVER_PAT}.${KVER_SUB}"
echo "[INFO] 源码树基线版本: ${KVER_FULL}"
if [[ "$KVER_FULL" != "6.6.50" ]]; then
    echo "[ERROR] 源码树版本为 ${KVER_FULL}，与目标设备 6.6.50 不一致！请通过 KERNEL_BRANCH=<精确6.6.50 tag> 重试。" >&2
    exit 2
fi

if [[ ! -d "${V4L2_DIR}/.git" ]]; then
    echo "=== [3/6] 拉取最新 v4l2loopback 源码 (原生适配 Linux 6.6 + KCFI) ==="
    git clone --depth=1 https://github.com/umlaeute/v4l2loopback.git "$V4L2_DIR"
fi

# 3. 完整保留设备真实 .config（保护 KCFI / ThinLTO / BTF / MODVERSIONS 结构体布局）
echo "=== [4/6] 注入设备真实 .config 并核查敏感配置项 ==="
gzip -dc "$(pwd)/device_config.gz" > "${KERNEL_DIR}/.config"
touch "${KERNEL_DIR}/.scmversion"

# 仅清洗 LOCALVERSION 防止重复拼接；绝不关闭 CFI_CLANG / LTO / BTF
"${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" \
    --set-str LOCALVERSION "" \
    --disable LOCALVERSION_AUTO

# 若启用了 BTF，确认编译机已安装 pahole
if grep -q '^CONFIG_DEBUG_INFO_BTF=y' "${KERNEL_DIR}/.config"; then
    command -v pahole >/dev/null 2>&1 || {
        echo "[ERROR] 设备内核启用了 CONFIG_DEBUG_INFO_BTF=y，请先在编译机执行: sudo apt-get install -y dwarves" >&2
        exit 3
    }
fi

# 若 CONFIG_TRIM_UNUSED_KSYMS 指向不存在的私有白名单文件，安全关闭裁剪（不影响符号 CRC）
if grep -q '^CONFIG_TRIM_UNUSED_KSYMS=y' "${KERNEL_DIR}/.config"; then
    WHITELIST_VAL=$(sed -n 's/^CONFIG_UNUSED_KSYMS_WHITELIST="\(.*\)"/\1/p' "${KERNEL_DIR}/.config" || true)
    if [[ -n "$WHITELIST_VAL" && ! -f "${KERNEL_DIR}/${WHITELIST_VAL}" ]]; then
        echo "[WARN] 缺失私有符号白名单 ${WHITELIST_VAL}，安全关闭 CONFIG_TRIM_UNUSED_KSYMS（不改变 KMI CRC）"
        "${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" \
            --disable TRIM_UNUSED_KSYMS \
            --set-str UNUSED_KSYMS_WHITELIST ""
    fi
fi

# 强制开启外置模块所需选项断言检查
for must_y in CONFIG_MODVERSIONS CONFIG_CFI_CLANG CONFIG_VIDEO_DEV; do
    if ! grep -q "^${must_y}=y" "${KERNEL_DIR}/.config"; then
        echo "[WARN] .config 中未检测到 ${must_y}=y，请核查 device_config.gz 是否完整！" >&2
    fi
done

MAKE_ARGS=(
    -C "$KERNEL_DIR"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    LOCALVERSION="$TARGET_SUFFIX"
    -j"$(nproc)"
)

make "${MAKE_ARGS[@]}" olddefconfig

# 4. 生成 Module.symvers 并立即执行 0x4e276f37 黄金锚点早期熔断
echo "=== [5/6] 生成内核符号表并校验 module_layout 黄金锚点 (${EXPECTED_LAYOUT_CRC}) ==="
if [[ -f "$(pwd)/Module.symvers" ]]; then
    cp "$(pwd)/Module.symvers" "${KERNEL_DIR}/Module.symvers"
    make "${MAKE_ARGS[@]}" modules_prepare
else
    make "${MAKE_ARGS[@]}" vmlinux modules
fi

BUILT_LAYOUT_CRC=$(awk '$2 == "module_layout" {print $1; exit}' "${KERNEL_DIR}/Module.symvers" || true)
echo "[CHECK] 编译产出 module_layout CRC = ${BUILT_LAYOUT_CRC:-MISSING} (设备黄金基准 = ${EXPECTED_LAYOUT_CRC})"
if [[ "${BUILT_LAYOUT_CRC,,}" != "${EXPECTED_LAYOUT_CRC,,}" ]]; then
    echo "[ABORT] module_layout CRC 未对齐！说明内核源码树或 struct module 影响项存在差异，已熔断中止！" >&2
    exit 4
fi
echo "[PASS] module_layout 黄金锚点 100% 比特级对齐！"

# 5. 编译 v4l2loopback.ko 并强制过零 Panic ELF ABI 门禁
echo "=== [6/6] 编译 v4l2loopback.ko 并执行零 Panic 门禁校验 ==="
make "${MAKE_ARGS[@]}" M="$V4L2_DIR" modules

OUT_KO="$(pwd)/v4l2loopback.ko"
cp "${V4L2_DIR}/v4l2loopback.ko" "$OUT_KO"

python3 "$(pwd)/verify_ko_abi.py" gate --baseline "$(pwd)/kmi_baseline.json" --ko "$OUT_KO"
echo "[SUCCESS] 门禁 APPROVED！产物可安全推送上机: ${OUT_KO}"
