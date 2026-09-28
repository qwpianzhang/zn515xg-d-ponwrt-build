#!/usr/bin/env bash
# =============================================================================
# ZNXT ZN515XG-D (Airoha AN7581) 三网通用 PonWrt 一键构建脚本
#
# 运行环境：Linux（Ubuntu 22.04/24.04 或 WSL2）。Windows 原生 Git-Bash 不支持。
#
#   ./build.sh              # lean ：PassWall 只带 xray-core（默认）
#   CORE_PROFILE=full ./build.sh   # full ：追加 sing-box / hysteria / naiveproxy 等
#   CORE_PROFILE=none ./build.sh   # none ：只编 LuCI，core 后续 opkg 安装
#
# 产物：out/<日期>-zn515xg-d/
#         *-sysupgrade.itb         PonWrt sysupgrade 镜像（本机型产物后缀是 .itb 不是 .bin）
#         *-recovery.itb           initramfs 恢复镜像（首次安装用 U-Boot Web 上传）
#         SHA256SUMS
#         config.buildinfo / .config
#         build.log
# =============================================================================
set -euo pipefail

PONWRT_REPO="${PONWRT_REPO:-https://github.com/pbs05/ponwrt.git}"
PONWRT_BRANCH="${PONWRT_BRANCH:-master}"
DEVICE="znxt_zn515xg-d"
BOARD_NAME="znxt,zn515xg-d"
CORE_PROFILE="${CORE_PROFILE:-lean}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/${STAMP}-zn515xg-d"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. 构建依赖（仅 apt 系；已装则跳过）
# ---------------------------------------------------------------------------
install_deps() {
  log "检查构建依赖"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y
    sudo apt-get install -y \
      ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
      bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk \
      gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool \
      lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
      libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev \
      libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build \
      p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
      python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig \
      texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd
  else
    echo "非 apt 系统，请自行安装 ImmortalWrt 构建依赖" >&2
  fi
}

# ---------------------------------------------------------------------------
# 1. 获取 PonWrt 源码
# ---------------------------------------------------------------------------
fetch_source() {
  log "获取 PonWrt 源码 ($PONWRT_BRANCH)"
  mkdir -p "$WORK"
  if [ ! -d "$WORK/ponwrt/.git" ]; then
    git clone --depth 1 -b "$PONWRT_BRANCH" "$PONWRT_REPO" "$WORK/ponwrt"
  else
    git -C "$WORK/ponwrt" fetch --depth 1 origin "$PONWRT_BRANCH"
    git -C "$WORK/ponwrt" checkout -f "$PONWRT_BRANCH"
  fi
}

# ---------------------------------------------------------------------------
# 2. feeds：写入 feeds.conf，update + install
# ---------------------------------------------------------------------------
setup_feeds() {
  log "写入 feeds.conf（官方默认源 + PassWall + OpenClash）"
  cp "$HERE/feeds.conf" "$WORK/ponwrt/feeds.conf"

  log "feeds update -a"
  "$WORK/ponwrt/scripts/feeds" update -a

  log "feeds install -a"
  "$WORK/ponwrt/scripts/feeds" install -a

  # 新增 feed 的包可能未被 -a 完全覆盖，逐个补装
  for p in luci-app-passwall luci-app-openclash luci-app-iptv luci-app-pon \
           xray-core sing-box chinadns-ng dns2socks ipt2socks microsocks \
           tcping v2ray-geodata igmpproxy; do
    "$WORK/ponwrt/scripts/feeds" install "$p" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# 3. 生成 .config：官方 an7581.config -> 只留 ZN515XG-D -> 追加本工程 seed
# ---------------------------------------------------------------------------
make_config() {
  log "基于 configs/an7581.config 生成 .config"
  cd "$WORK/ponwrt"
  cp configs/an7581.config .config

  # 3.1 关掉除 ZN515XG-D 之外的全部 AN7581 设备（避免产出混淆机型）
  sed -i -E 's#^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_(.+)=[ym]$#\# CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_\1 is not set#' .config
  sed -i -E 's#^CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_(.+)=.*$#\# CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_\1 is not set#' .config
  cat >> .config <<EOF
CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y
CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_${DEVICE}=""
EOF

  # 3.2 追加项目配置片段
  cat "$HERE/zn515xg-d.seed" >> .config

  # 3.3 core 体积策略
  case "$CORE_PROFILE" in
    none)
      sed -i -E 's#^CONFIG_PACKAGE_xray-core=[ym]$#\# CONFIG_PACKAGE_xray-core is not set#' .config
      ;;
    full)
      cat >> .config <<'EOF'
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_hysteria=y
CONFIG_PACKAGE_naiveproxy=y
CONFIG_PACKAGE_shadowsocks-rust=y
CONFIG_PACKAGE_shadowsocksr-libev=y
CONFIG_PACKAGE_simple-obfs=y
CONFIG_PACKAGE_shadow-tls=y
CONFIG_PACKAGE_xray-plugin=y
CONFIG_PACKAGE_v2ray-plugin=y
CONFIG_PACKAGE_geoview=y
EOF
      ;;
    lean|*) ;;
  esac

  log "make defconfig"
  make defconfig 2>&1 | tail -20

  # 3.4 自检：确认目标机型正确
  echo "---- 目标设备自检 ----"
  grep -E "^CONFIG_TARGET_BOARD=|^CONFIG_TARGET_SUBTARGET=|^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y" .config
  if ! grep -q "^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y" .config; then
    echo "FATAL: ${DEVICE} 未出现在最终 .config 中" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 4. 注入自定义 overlay（默认关闭代理）
# ---------------------------------------------------------------------------
apply_files() {
  log "注入 files/ overlay"
  mkdir -p "$WORK/ponwrt/files"
  cp -a "$HERE/files/." "$WORK/ponwrt/files/"
}

# ---------------------------------------------------------------------------
# 5. 编译
# ---------------------------------------------------------------------------
compile() {
  cd "$WORK/ponwrt"
  log "make download"
  make download -j"$(nproc)" 2>&1 | tail -5 || true

  log "make -j$(nproc)（日志见 $DEST/build.log）"
  mkdir -p "$DEST"
  if make -j"$(nproc)" V=s >"$DEST/build.log" 2>&1; then
    echo "BUILD OK"
  else
    echo "BUILD FAILED —— 使用 make -j1 V=s 定位"
    make -j1 V=s >"$DEST/build-fail.log" 2>&1 || true
    echo "失败日志尾部："
    tail -n 60 "$DEST/build-fail.log" || true
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 6. 收产物
# ---------------------------------------------------------------------------
collect() {
  cd "$WORK/ponwrt"
  local BIN="bin/targets/airoha/an7581"
  log "收集产物自 $BIN"
  mkdir -p "$DEST"
  cp -a "$BIN"/*.itb        "$DEST"/ 2>/dev/null || true
  cp -a "$BIN"/*.bin        "$DEST"/ 2>/dev/null || true
  cp -a "$BIN"/SHA256SUMS   "$DEST"/ 2>/dev/null || true
  cp -a "$BIN"/config.buildinfo "$DEST"/ 2>/dev/null || true
  cp -a .config             "$DEST"/config.full 2>/dev/null || true
  cp -a feeds.conf          "$DEST"/feeds.conf 2>/dev/null || true

  # 自建 SHA256SUMS（PonWrt 若已生成则覆盖为只含镜像的版本）
  cd "$DEST"
  if ls ./*.itb ./*.bin >/dev/null 2>&1; then
    sha256sum ./*.itb ./*.bin 2>/dev/null > SHA256SUMS.mirror || true
  fi

  # 包清单（用于验收核对）
  "$WORK/ponwrt/scripts/diffconfig.sh" > "$DEST/diffconfig.txt" 2>/dev/null || true
  if ls "$WORK/ponwrt/bin/packages"/aarch64_cortex-a53/base/*.ipk >/dev/null 2>&1; then
    ls -1 "$WORK/ponwrt/bin/packages"/aarch64_cortex-a53/*/*.ipk \
      | xargs -n1 basename | sort > "$DEST/packages-in-tree.txt" 2>/dev/null || true
  fi

  log "产物目录：$DEST"
  ls -lh "$DEST"
}

install_deps
fetch_source
setup_feeds
make_config
apply_files
compile
collect
