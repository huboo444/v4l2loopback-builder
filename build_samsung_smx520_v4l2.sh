#!/usr/bin/env bash
# File (CI Repo): build_samsung_smx520_v4l2.sh
# 契约：基于三星 SM-X520 官方开源内核树 + AOSP Clang 18 (r510928) 构建与 0x4e276f37 比特级对齐的 v4l2loopback.ko
# 输入环境变量（二选一）：
#   KERNEL_ARCHIVE   : 本地三星开源压缩包路径（支持完整 Opensource.zip 或 Kernel.tar.gz / .tar.xz）
#   KERNEL_GIT_URL   : 可选，直接指定含三星 SM-X520 补丁的内核 Git 仓库 URL（配套 KERNEL_GIT_BRANCH）
set -euo pipefail

WORKDIR="$(pwd)/smx520_v4l2_build"
CLANG_DIR="${WORKDIR}/clang-r510928"
CLANG_REPO="${WORKDIR}/clang_repo"
SRC_STAGE="${WORKDIR}/kernel_src"
V4L2_DIR="${WORKDIR}/v4l2loopback"

TARGET_SUFFIX="${TARGET_SUFFIX:--android15-8-abX520XXS4AYG5-4k}"
EXPECTED_LAYOUT_CRC="${EXPECTED_LAYOUT_CRC:-0x4e276f37}"

REQUIRED_SAMSUNG_CONFIGS=(
    "CONFIG_SAMSUNG_FREECESS"
    "CONFIG_SAMSUNG_PRODUCT_SHIP"
    "CONFIG_SEC_DEBUG_AUTO_COMMENT"
    "CONFIG_SEC_DEBUG_BASE_BUILT_IN"
    "CONFIG_SEC_DEBUG_BUG_ON_SLUB_CORRUPTION"
    "CONFIG_SEC_DEBUG_BUILT"
    "CONFIG_SEC_DEBUG_EXCEPTION_STACK"
    "CONFIG_SEC_DEBUG_FAULT_MSG_ADV"
    "CONFIG_SEC_DEBUG_MEMTAB"
    "CONFIG_SEC_DEBUG_PM_DEVICE_INFO"
    "CONFIG_SEC_DEBUG_QSPIN_OWNER"
    "CONFIG_SEC_DEBUG_TASK_IN_STATE_INFO"
)

for req in device_config.gz kmi_baseline.json verify_ko_abi.py; do
    [[ -f "$req" ]] || { echo "[ERROR] 当前目录缺失必要输入文件: $req" >&2; exit 1; }
done
[[ "$(uname -m)" == "x86_64" ]] || { echo "[ERROR] AOSP Clang r510928 仅支持 x86_64 宿主机" >&2; exit 1; }

mkdir -p "$WORKDIR"

fetch_aosp_clang_r510928() {
    local clang_dir="$1"
    local clang_repo="$2"
    local repo_url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
    local -a candidate_refs=("android15-release" "android15-qpr1-release" "android15-gsi" "main")

    if [[ -x "${clang_dir}/bin/clang" ]]; then
        echo "[SKIP] 已存在本地 Clang: ${clang_dir}"
        return 0
    fi

    for ref in "${candidate_refs[@]}"; do
        echo "[TRY] 探测 AOSP 分支 ${ref}..."
        rm -rf "$clang_repo"
        if ! git clone --depth=1 --filter=blob:none --no-checkout --single-branch \
            -b "$ref" "$repo_url" "$clang_repo" >/dev/null 2>&1; then
            continue
        fi
        if [[ "$(git -C "$clang_repo" ls-tree -d --name-only HEAD clang-r510928 2>/dev/null || true)" != "clang-r510928" ]]; then
            rm -rf "$clang_repo"
            continue
        fi
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
            echo "[PASS] 工具链就绪 (ref=${ref}): $("${clang_dir}/bin/clang" --version | head -n 1)"
            return 0
        fi
        rm -rf "$clang_repo"
    done
    echo "[ERROR] 未能获取 AOSP clang-r510928" >&2
    return 1
}

# 自动解包三星官方 Opensource.zip（含嵌套 Kernel.tar.gz）或直接解包 Kernel.tar.gz / 克隆 Git 树
prepare_kernel_source() {
    rm -rf "$SRC_STAGE"
    mkdir -p "$SRC_STAGE"

    if [[ -n "${KERNEL_GIT_URL:-}" ]]; then
        echo "[INFO] 正在从 Git 仓库克隆内核树: ${KERNEL_GIT_URL}"
        if [[ -n "${KERNEL_GIT_BRANCH:-}" ]]; then
            git clone --depth=1 -b "$KERNEL_GIT_BRANCH" "$KERNEL_GIT_URL" "$SRC_STAGE"
        else
            git clone --depth=1 "$KERNEL_GIT_URL" "$SRC_STAGE"
        fi
        return 0
    fi

    local archive="${KERNEL_ARCHIVE:-}"
    [[ -n "$archive" && -f "$archive" ]] || {
        echo "[ERROR] 未提供有效的 KERNEL_ARCHIVE 或 KERNEL_GIT_URL" >&2
        return 1
    }

    echo "[INFO] 正在解包三星内核源码包: ${archive}"
    case "$archive" in
        *.zip)
            local outer_dir="${WORKDIR}/zip_outer"
            rm -rf "$outer_dir"
            mkdir -p "$outer_dir"
            unzip -q "$archive" -d "$outer_dir"
            # 优先查找三星官方内层 Kernel.tar.gz / kernel*.tar.*
            local inner_tar
            inner_tar=$(find "$outer_dir" -maxdepth 3 -type f \( -iname 'Kernel.tar*' -o -iname '*kernel*.tar*' \) | head -n 1 || true)
            if [[ -n "$inner_tar" ]]; then
                echo "[INFO] 命中内层内核归档: ${inner_tar}，正在展开..."
                tar -xf "$inner_tar" -C "$SRC_STAGE"
                rm -rf "$outer_dir"
            else
                mv "$outer_dir"/* "$SRC_STAGE"/
                rm -rf "$outer_dir"
            fi
            ;;
        *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
            tar -xf "$archive" -C "$SRC_STAGE"
            ;;
        *)
            echo "[ERROR] 不支持的压缩包格式: ${archive}" >&2
            return 1
            ;;
    esac
}

# 在展开目录中精准定位 6.6 内核根目录（必须同时包含 arch/arm64 与 VERSION=6 / PATCHLEVEL=6）
locate_kernel_root() {
    local cand dir maj pat
    while IFS= read -r cand; do
        dir="$(dirname "$cand")"
        [[ -d "${dir}/arch/arm64" && -f "${dir}/Kconfig" ]] || continue
        maj=$(awk '/^VERSION =/{print $3; exit}' "$cand" || true)
        pat=$(awk '/^PATCHLEVEL =/{print $3; exit}' "$cand" || true)
        if [[ "$maj" == "6" && "$pat" == "6" ]]; then
            echo "$dir"
            return 0
        fi
    done < <(find "$SRC_STAGE" -maxdepth 4 -type f -name 'Makefile' | sort)
    return 1
}

# 10 秒早期门禁：验证全部 12 项三星 OEM 配置在 olddefconfig 后存活，杜绝盲跑 7 分钟
assert_samsung_configs_survived() {
    local dot_config="$1"
    local missing=0
    echo "=== 校验 12 项三星 OEM 核心配置存活状态 ==="
    for key in "${REQUIRED_SAMSUNG_CONFIGS[@]}"; do
        if grep -q "^${key}=y" "$dot_config"; then
            echo "  [KEEP] ${key}=y"
        else
            echo "  [LOST] ${key} 未保持 =y（源码树缺少三星 OEM 补丁或依赖未满足！）" >&2
            missing=$((missing + 1))
        fi
    done
    if (( missing > 0 )); then
        echo "[ABORT] 有 ${missing} 项三星核心配置在 olddefconfig 后丢失，无法命中 0x4e276f37，立即中止！" >&2
        return 1
    fi
    echo "[PASS] 全部 12 项三星 OEM 扩展配置 100% 存活！"
    return 0
}

echo "=== [1/6] 准备 AOSP Clang 18 (clang-r510928) ==="
fetch_aosp_clang_r510928 "$CLANG_DIR" "$CLANG_REPO"
export PATH="${CLANG_DIR}/bin:${PATH}"

echo "=== [2/6] 准备三星 SM-X520 内核源码树 ==="
prepare_kernel_source
KERNEL_DIR="$(locate_kernel_root)" || {
    echo "[ERROR] 未能在源码包中定位到 Linux 6.6 (arm64) 内核根目录！" >&2
    find "$SRC_STAGE" -maxdepth 3 >&2
    exit 2
}
KVER_SUB=$(awk '/^SUBLEVEL =/{print $3; exit}' "${KERNEL_DIR}/Makefile")
echo "[PASS] 定位到内核根目录: ${KERNEL_DIR} (版本=6.6.${KVER_SUB})"

echo "=== [3/6] 拉取最新 v4l2loopback 源码 ==="
if [[ ! -d "${V4L2_DIR}/.git" ]]; then
    git clone --depth=1 https://github.com/umlaeute/v4l2loopback.git "$V4L2_DIR"
fi

echo "=== [4/6] 注入设备真实 .config 并执行 12 项三星配置存活门禁 ==="
gzip -dc "$(pwd)/device_config.gz" > "${KERNEL_DIR}/.config"
touch "${KERNEL_DIR}/.scmversion"

# 安全清洗非 ABI 阻塞项（严禁触碰 KASAN / CFI_CLANG / LTO / MODVERSIONS / DEBUG_INFO_BTF*）
"${KERNEL_DIR}/scripts/config" --file "${KERNEL_DIR}/.config" \
    --set-str LOCALVERSION "" \
    --disable LOCALVERSION_AUTO \
    --disable WERROR \
    --set-str SYSTEM_TRUSTED_KEYS "" \
    --set-str SYSTEM_REVOCATION_KEYS ""

# 仅当私有白名单文件在当前树中缺失时才关闭符号裁剪（不影响已有导出符号 CRC）
if grep -q '^CONFIG_TRIM_UNUSED_KSYMS=y' "${KERNEL_DIR}/.config"; then
    WHITELIST_VAL=$(sed -n 's/^CONFIG_UNUSED_KSYMS_WHITELIST="\(.*\)"/\1/p' "${KERNEL_DIR}/.config" || true)
    if [[ -n "$WHITELIST_VAL" && ! -f "${KERNEL_DIR}/${WHITELIST_VAL}" ]]; then
        echo "[WARN] 缺失私有符号白名单 ${WHITELIST_VAL}，关闭 TRIM_UNUSED_KSYMS"
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

if [[ -f "$(pwd)/diff_kconfig.py" ]]; then
    python3 "$(pwd)/diff_kconfig.py" \
        --device "$(pwd)/device_config.gz" \
        --built "${KERNEL_DIR}/.config" \
        --out "$(pwd)/kconfig_diff.json"
fi

assert_samsung_configs_survived "${KERNEL_DIR}/.config"

echo "=== [5/6] 受控构建 vmlinux 以生成 vmlinux.symvers 并校验 0x4e276f37 黄金锚点 ==="
VMLINUX_RC=0
make "${MAKE_ARGS[@]}" vmlinux || VMLINUX_RC=$?
echo "[INFO] make vmlinux 结束，退出码=${VMLINUX_RC}"

if [[ ! -s "${KERNEL_DIR}/vmlinux.symvers" ]]; then
    echo "[ERROR] 未能生成非空 vmlinux.symvers！说明在 MODPOST 之前发生编译错误，请检查上方日志。" >&2
    exit 4
fi

SYMVERS_LINES=$(wc -l < "${KERNEL_DIR}/vmlinux.symvers")
echo "[INFO] vmlinux.symvers 导出符号总数=${SYMVERS_LINES}"
if (( SYMVERS_LINES < 1000 )); then
    echo "[ERROR] vmlinux.symvers 符号数过少 (${SYMVERS_LINES})，熔断中止！" >&2
    exit 4
fi

# 删除残缺 vmlinux，使外部模块干净跳过旧版 pahole BTF 生成
rm -f "${KERNEL_DIR}/vmlinux" "${KERNEL_DIR}"/.tmp_vmlinux*

make "${MAKE_ARGS[@]}" modules_prepare
cp "${KERNEL_DIR}/vmlinux.symvers" "${KERNEL_DIR}/Module.symvers"

# 全量 355 项基线符号 X 光透视
if [[ -f "$(pwd)/xray_symvers.py" ]]; then
    python3 "$(pwd)/xray_symvers.py" \
        --baseline "$(pwd)/kmi_baseline.json" \
        --symvers "${KERNEL_DIR}/Module.symvers" \
        --out "$(pwd)/crc_xray_report.json"
fi

BUILT_CRC=$(awk '$2 == "module_layout" {print $1; exit}' "${KERNEL_DIR}/Module.symvers" || true)
echo "[CHECK] built module_layout = ${BUILT_CRC:-MISSING} (device baseline = ${EXPECTED_LAYOUT_CRC})"
if [[ "${BUILT_CRC,,}" != "${EXPECTED_LAYOUT_CRC,,}" ]]; then
    echo "[ABORT] module_layout CRC 仍未对齐！请查看 Artifact 中的 kconfig_diff.json 与 crc_xray_report.json。" >&2
    exit 5
fi

for req_sym in __video_register_device video_unregister_device video_ioctl2 v4l2_device_register; do
    if ! awk -v s="$req_sym" '$2 == s {found=1; exit} END {exit !found}' "${KERNEL_DIR}/Module.symvers"; then
        echo "[ABORT] Module.symvers 缺失内建 V4L2 核心符号: ${req_sym}" >&2
        exit 6
    fi
done
echo "[PASS] module_layout (${EXPECTED_LAYOUT_CRC}) 与 V4L2 核心符号 100% 比特级对齐！"

echo "=== [6/6] 编译 v4l2loopback.ko 并强制过零 Panic ELF ABI 门禁 ==="
make "${MAKE_ARGS[@]}" KCFLAGS="-Wno-error" M="$V4L2_DIR" modules
cp "${V4L2_DIR}/v4l2loopback.ko" ./v4l2loopback.ko

llvm-nm -u ./v4l2loopback.ko | awk '{print $2}' | sort -u > ./v4l2loopback_needed_syms.txt
python3 verify_ko_abi.py gate --baseline kmi_baseline.json --ko ./v4l2loopback.ko --json | tee gate_report.json
python3 verify_ko_abi.py gate --baseline kmi_baseline.json --ko ./v4l2loopback.ko
echo "[SUCCESS] 门禁 APPROVED！产物可安全推送上机: $(pwd)/v4l2loopback.ko"
