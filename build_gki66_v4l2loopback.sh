#!/usr/bin/env bash
# File: build_gki66_v4l2loopback.sh
# 架构师定型版 v3.0 (候选分支探测 + 磁盘防爆 + BTF 自适应 + 0x4e276f37 熔断 + ABI 门禁)
set -euo pipefail

WORKDIR="$(pwd)/gki66_v4l2_build"
CLANG_DIR="${WORKDIR}/clang-r510928"
KERNEL_DIR="${WORKDIR}/common"
V4L2_DIR="${WORKDIR}/v4l2loopback"

TARGET_SUFFIX="${TARGET_SUFFIX:--android15-8-abX520XXS4AYG5-4k}"
EXPECTED_LAYOUT_CRC="${EXPECTED_LAYOUT_CRC:-0x4e276f37}"
KERNEL_BRANCH="${KERNEL_BRANCH:-android15-6.6-2024-10_r1}"

for req in device_config.gz kmi_baseline.json verify_ko_abi.py; do
    [[ -f "$req" ]] || { echo "[ERROR] 缺失必要输入文件: $req" >&2; exit 1; }
done
[[ "$(uname -m)" == "x86_64" ]] || { echo "[ERROR] 仅支持 x86_64 Linux 宿主机" >&2; exit 1; }

mkdir -p "$WORKDIR"

# 1. 生产级 Clang 检出函数 (候选分支探测 + 0.2s 纯 Tree 断言 + 版本校验)
fetch_aosp_clang_r510928() {
    local clang_dir="$1"
    local clang_repo="$2"
    local repo_url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
    local -a candidate_refs=(
        "android15-release"
        "android15-qpr1-release"
        "android15-gsi"
        "main"
    )

    if [[ -x "${clang_dir}/bin/clang" ]]; then
        echo "[SKIP] 已存在本地 Clang: ${clang_dir}"
        return 0
    fi

    for ref in "${candidate_refs[@]}"; do
        echo "[TRY] 探测分支 ${ref} 是否包含 clang-r510928..."
        rm -rf "$clang_repo"

        if ! git clone --depth=1 --filter=blob:none --no-checkout --single-branch \
            -b "$ref" "$repo_url" "$clang_repo" >/dev/null 2>&1; then
            echo "[SKIP] 分支 ${ref} 克隆失败，尝试下一候选"
            continue
        fi

        # 0.2 秒纯 Tree 断言：不下载任何 Blob 即可确认目录是否存在
        if [[ "$(git -C "$clang_repo" ls-tree -d --name-only HEAD clang-r510928 2>/dev/null || true)" != "clang-r510928" ]]; then
            echo "[SKIP] 分支 ${ref} 中不含 clang-r510928 目录，跳过"
            rm -rf "$clang_repo"
            continue
        fi

        echo "[HIT] 在分支 ${ref} 命中 clang-r510928，开始稀疏拉取实体..."
        (
            cd "$clang_repo"
            git sparse-checkout init --cone
            git sparse-checkout set clang-r510928
            git checkout -q "$ref"
        )

        if [[ -x "${clang_repo}/clang-r510928/bin/clang" ]]; then
            rm -rf "$clang_dir"
            mv "${clang_repo}/clang-r510928" "$clang_dir"
            rm -rf "$clang_repo"

            local ver_out
            ver_out="$("${clang_dir}/bin/clang" --version | head -n 1)"
            echo "[PASS] 工具链就绪 (ref=${ref}): ${ver_out}"
            if [[ "$ver_out" != *"r510928"* && "$ver_out" != *"18.0.0"* ]]; then
                echo "[WARN] 版本串未显式匹配 r510928/18.0.0，请复核 KCFI 兼容性" >&2
            fi
            return 0
        fi
        rm -rf "$clang_repo"
    done

    echo "[FAIL] 所有候选分支均未能获取有效的 clang-r510928" >&2
    return 1
}

echo "=== [1/6] 获取 AOSP Clang 18 (clang-r510928) ==="
fetch_aosp_clang_r510928 "$CLANG_DIR" "${WORKDIR}/clang_repo"

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
    echo "[ERROR] 源码树版本为 ${KVER_FULL}，与目标设备 6.6.50 不一致！" >&2
    exit 2
fi

if [[ ! -d "${V4L2_DIR}/.git" ]]; then
    echo "=== [3/6] 拉取最新 v4l2loopback 源码 ==="
    git clone --depth=1 https://github.com/umlaeute/v4l2loopback.git "$V4L2_DIR"
fi

# 3. 注入设备真实 .config 并清洗非 ABI 阻塞项
echo "=== [4/6] 注入真实 .config 并清洗非 ABI 阻塞项 ==="
gzip -dc "$(pwd)/device_config.gz" > "${KERNEL_DIR}/.config"
touch "${KERNEL_DIR}/.scmversion"

"${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" \
    --set-str LOCALVERSION "" \
    --disable LOCALVERSION_AUTO \
    --disable WERROR \
    --set-str SYSTEM_TRUSTED_KEYS "" \
    --set-str SYSTEM_REVOCATION_KEYS ""

# 仅当私有白名单文件在公共树不存在时关闭符号裁剪（不影响已有符号 CRC）
if grep -q '^CONFIG_TRIM_UNUSED_KSYMS=y' "${KERNEL_DIR}/.config"; then
    WHITELIST_VAL=$(sed -n 's/^CONFIG_UNUSED_KSYMS_WHITELIST="\(.*\)"/\1/p' "${KERNEL_DIR}/.config" || true)
    if [[ -n "$WHITELIST_VAL" && ! -f "${KERNEL_DIR}/${WHITELIST_VAL}" ]]; then
        echo "[WARN] 缺失私有符号白名单 ${WHITELIST_VAL}，安全关闭 CONFIG_TRIM_UNUSED_KSYMS"
        "${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" \
            --disable TRIM_UNUSED_KSYMS \
            --set-str UNUSED_KSYMS_WHITELIST ""
    fi
fi

MAKE_ARGS=(
    -C "$KERNEL_DIR"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    LOCALVERSION="$TARGET_SUFFIX"
    -j"$(nproc)"
)

make "${MAKE_ARGS[@]}" olddefconfig

# 4. 按 BTF_MODULES 自适应构建目标并执行 0x4e276f37 熔断
echo "=== [5/6] 自适应构建符号表并校验 module_layout 黄金锚点 (${EXPECTED_LAYOUT_CRC}) ==="
if grep -q '^CONFIG_DEBUG_INFO_BTF_MODULES=y' "${KERNEL_DIR}/.config"; then
    command -v pahole >/dev/null 2>&1 || { echo "[ERROR] 缺少 pahole (dwarves)" >&2; exit 3; }
    echo "[INFO] 检测到 CONFIG_DEBUG_INFO_BTF_MODULES=y，构建 vmlinux + vmlinux.symvers..."
    make "${MAKE_ARGS[@]}" modules_prepare vmlinux vmlinux.symvers
else
    echo "[INFO] 未启用 BTF_MODULES，走极速路径 modules_prepare + vmlinux.symvers..."
    make "${MAKE_ARGS[@]}" modules_prepare vmlinux.symvers
fi

cp "${KERNEL_DIR}/vmlinux.symvers" "${KERNEL_DIR}/Module.symvers"

BUILT_CRC=$(awk '$2 == "module_layout" {print $1; exit}' "${KERNEL_DIR}/Module.symvers" || true)
echo "[CHECK] built module_layout = ${BUILT_CRC:-MISSING} (device baseline = ${EXPECTED_LAYOUT_CRC})"
if [[ "${BUILT_CRC,,}" != "${EXPECTED_LAYOUT_CRC,,}" ]]; then
    echo "[ABORT] module_layout CRC 偏移！说明内核源码树或配置存在差异，已熔断！" >&2
    exit 4
fi
echo "[PASS] module_layout 黄金锚点 100% 比特级对齐！"

# 5. 编译 v4l2loopback.ko 并执行零 Panic 门禁校验
echo "=== [6/6] 编译 v4l2loopback.ko 并执行零 Panic 门禁校验 ==="
make "${MAKE_ARGS[@]}" KCFLAGS="-Wno-error" M="$V4L2_DIR" modules
cp "${V4L2_DIR}/v4l2loopback.ko" ./v4l2loopback.ko

# 导出未定义符号清单（供上机前核验）+ 执行零 Panic 门禁
llvm-nm -u ./v4l2loopback.ko | awk '{print $2}' | sort -u > ./v4l2loopback_needed_syms.txt
python3 verify_ko_abi.py gate --baseline kmi_baseline.json --ko ./v4l2loopback.ko --json | tee gate_report.json
python3 verify_ko_abi.py gate --baseline kmi_baseline.json --ko ./v4l2loopback.ko
echo "[SUCCESS] 门禁 APPROVED！产物已就绪: ./v4l2loopback.ko"
