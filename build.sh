#!/usr/bin/env bash
# =============================================================================
# ZNXT ZN515XG-D (Airoha AN7581) 三网通用 PonWrt 一键构建脚本
# 代理方案：PassWall2 + OpenClash（PassWall v1 已移除）
#
# 运行环境：Linux（Ubuntu 22.04/24.04 或 WSL2）。Windows 原生 Git-Bash 不支持。
#
#   ./build.sh                       # lean ：PassWall 只带 xray-core（默认）
#   CORE_PROFILE=full ./build.sh     # full ：追加 sing-box / hysteria 等
#   CORE_PROFILE=none ./build.sh     # none ：只编 LuCI，core 后续 opkg 装
#
# 产物：out/<时间戳>-zn515xg-d/
#         *-sysupgrade.itb             sysupgrade 镜像（本机型是 .itb 不是 .bin）
#         *-recovery.itb               initramfs 恢复镜像
#         SHA256SUMS / SHA256SUMS.mirror
#         config.full                  最终 .config
#         feeds.conf                   实际使用的 feeds
#         packages-built.txt           已编入/已产出的包清单
#         验收报告.txt                  target/profile/包 核对结果
#         build.log
# =============================================================================
set -euo pipefail

PONWRT_REPO="${PONWRT_REPO:-https://github.com/pbs05/ponwrt.git}"
PONWRT_BRANCH="${PONWRT_BRANCH:-master}"
DEVICE="znxt_zn515xg-d"
DEVICE_DTS="znxt,zn515xg-d"
CORE_PROFILE="${CORE_PROFILE:-lean}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/${STAMP}-zn515xg-d"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# 0. 构建依赖
# ---------------------------------------------------------------------------
install_deps() {
  log "安装构建依赖"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y || true
    sudo apt-get install -y --no-install-recommends \
      ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
      bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk \
      gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool \
      libc6-dev-i386 libelf-dev libglib2.0-dev libgmp-dev libltdl-dev \
      libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev \
      libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build \
      p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
      python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig \
      texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd \
      || sudo apt-get install -y --no-install-recommends \
      build-essential clang flex bison gawk gettext git libncurses-dev libssl-dev \
      python3 python3-ply unzip zlib1g-dev rsync ccache device-tree-compiler \
      || echo "WARN: 部分依赖安装失败，继续尝试编译"
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
    rm -rf "$WORK/ponwrt"
    git clone --depth 1 -b "$PONWRT_BRANCH" "$PONWRT_REPO" "$WORK/ponwrt"
  else
    git -C "$WORK/ponwrt" fetch --depth 1 origin "$PONWRT_BRANCH" || true
    git -C "$WORK/ponwrt" checkout -f "$PONWRT_BRANCH" || true
  fi
}

# ---------------------------------------------------------------------------
# 2. feeds
# ---------------------------------------------------------------------------
setup_feeds() {
  log "写入 feeds.conf"
  cp "$HERE/feeds.conf" "$WORK/ponwrt/feeds.conf"

  log "feeds update -a"
  "$WORK/ponwrt/scripts/feeds" update -a 2>&1 | tail -20

  log "feeds install -a"
  "$WORK/ponwrt/scripts/feeds" install -a 2>&1 | tail -10

  log "补装关键包（新 feed 可能未被 -a 覆盖）"
  for p in luci-app-passwall2 luci-app-openclash luci-app-iptv luci-app-pon \
           xray-core sing-box chinadns-ng tcping \
           v2ray-geoip v2ray-geosite geoview \
           igmpproxy omcproxy ruby-yaml luci-compat lyaml; do
    "$WORK/ponwrt/scripts/feeds" install "$p" >/dev/null 2>&1 || true
  done
}

# ---------------------------------------------------------------------------
# 3. 生成 .config
# ---------------------------------------------------------------------------
make_config() {
  log "基于 configs/an7581.config 生成 .config"
  cd "$WORK/ponwrt"
  cp configs/an7581.config .config

  # 3.1 关掉除 ZN515XG-D 之外的全部 AN7581 设备
  sed -i -E 's#^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_(.+)=[ym]$#\# CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_\1 is not set#' .config
  sed -i -E 's#^CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_(.+)=.*$#\# CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_\1 is not set#' .config

  cat >> .config <<EOF
CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y
CONFIG_TARGET_DEVICE_PACKAGES_airoha_an7581_DEVICE_${DEVICE}=""
EOF

  # 3.2 追加项目配置片段
  cat "$HERE/zn515xg-d.seed" >> .config

  # 3.3 core 体积策略
  #
  # 注意：PassWall2 的 Basic_Core 是一个 choice（Xray / SingBox / All），
  # 没有「不选 core」的选项，所以 none 也仍会带 xray-core（体积约 15-20MB）。
  # 想要完全不带 core，得把 luci-app-passwall2 一起去掉。
  case "$CORE_PROFILE" in
    none)
      # 仍然选 Xray（choice 无空选项），但不追加任何额外 core
      sed -i -E 's#^CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_All=[ym]$#\# CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_All is not set#' .config
      grep -q '^CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_Xray=y' .config || \
        echo 'CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_Xray=y' >> .config
      ;;
    full)
      cat >> .config <<'EOF'
# PassWall2：放开完整 core 与插件（体积显著增大）
# CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_Xray is not set
CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_All=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Haproxy=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Shadowsocks_Rust_Client=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_ShadowsocksR_Libev_Client=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Simple_Obfs=y
CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_V2ray_Plugin=y
EOF
      ;;
    lean|*) ;;
  esac

  log "make defconfig"
  make defconfig 2>&1 | tail -20

  # 3.4 自检
  echo "---- 目标设备自检 ----"
  grep -E "^CONFIG_TARGET_BOARD=|^CONFIG_TARGET_SUBTARGET=" .config || true
  echo "选中设备数量: $(grep -c '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_.*=y' .config)"
  grep "^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_.*=y" .config || true
  if ! grep -q "^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y" .config; then
    echo "FATAL: ${DEVICE} 未出现在最终 .config 中" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 4. overlay（默认关闭代理）
# ---------------------------------------------------------------------------
apply_files() {
  log "注入 files/ overlay"
  mkdir -p "$WORK/ponwrt/files"
  cp -a "$HERE/files/." "$WORK/ponwrt/files/"
  find "$WORK/ponwrt/files" -type f | sed "s#^#  overlay: #"
}

# ---------------------------------------------------------------------------
# 5. 编译
# ---------------------------------------------------------------------------
compile() {
  cd "$WORK/ponwrt"

  log "make download"
  for i in 1 2 3; do
    if make download -j"$(nproc)" >"$DEST/download.log" 2>&1; then break; fi
    echo "download 第 $i 次失败，重试"
    sleep 5
  done
  tail -5 "$DEST/download.log" || true

  # 预检缺失源码包（会给出 make 报错原因）
  if make download >"$DEST/download-check.log" 2>&1; then
    echo "download 完整"
  else
    echo "WARN: 仍有源码包缺失，见 download-check.log"
  fi

  log "make -j$(nproc)（日志 $DEST/build.log）"
  if make -j"$(nproc)" >"$DEST/build.log" 2>&1; then
    echo "BUILD OK"
    tail -20 "$DEST/build.log"
  else
    echo "BUILD FAILED —— 单线程复现定位"
    make -j1 V=s >"$DEST/build-fail.log" 2>&1 || true
    {
      echo "===== 错误行 ====="
      grep -n -E "Error [0-9]|: error:|No such file|command not found|is not set|failed" "$DEST/build-fail.log" | head -60
      echo ""
      echo "===== 日志尾部 ====="
      tail -n 80 "$DEST/build-fail.log"
    } > "$DEST/failure-summary.txt"
    cat "$DEST/failure-summary.txt"
    # build-fail.log 可能极大，只保留摘要
    rm -f "$DEST/build-fail.log"
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
  ls -lh "$BIN" 2>/dev/null || true

  cp -a "$BIN"/*.itb            "$DEST"/ 2>/dev/null || true
  cp -a "$BIN"/*.bin            "$DEST"/ 2>/dev/null || true
  cp -a "$BIN"/SHA256SUMS       "$DEST"/ 2>/dev/null || true
  cp -a "$BIN"/config.buildinfo "$DEST"/ 2>/dev/null || true
  cp -a .config                 "$DEST"/config.full    2>/dev/null || true
  cp -a feeds.conf              "$DEST"/feeds.conf     2>/dev/null || true

  # 包清单
  if ls "$WORK/ponwrt/bin/packages"/aarch64_cortex-a53/*/*.ipk >/dev/null 2>&1; then
    ls -1 "$WORK/ponwrt/bin/packages"/aarch64_cortex-a53/*/*.ipk \
      | xargs -n1 basename | sort -u > "$DEST/packages-built.txt"
  fi
  # 编入 rootfs 的包（从 .config 提取 =y）
  grep -E "^CONFIG_PACKAGE_.+=y$" .config | sed -E 's/^CONFIG_PACKAGE_//; s/=y$//' \
    | sort > "$DEST/packages-in-rootfs.txt"

  cd "$DEST"
  if ls ./*.itb ./*.bin >/dev/null 2>&1; then
    sha256sum ./*.itb ./*.bin 2>/dev/null > SHA256SUMS.mirror || true
  fi

  log "产物目录：$DEST"
  ls -lh "$DEST"
}

# ---------------------------------------------------------------------------
# 7. 验收核对
# ---------------------------------------------------------------------------
verify() {
  local R="$DEST/验收报告.txt"
  local ok=0 bad=0
  chk() { # $1=说明  $2=命令(返回0为通过)
    if eval "$2" >/dev/null 2>&1; then printf '  [PASS] %s\n' "$1" >>"$R"; ok=$((ok+1));
    else printf '  [FAIL] %s\n' "$1" >>"$R"; bad=$((bad+1)); fi
  }

  {
    echo "=============================================================="
    echo " ZNXT ZN515XG-D / AN7581 PonWrt 固件验收报告"
    echo " 生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo " core_profile: $CORE_PROFILE"
    echo "=============================================================="
    echo ""
    echo "[1] 镜像文件"
  } > "$R"

  if ls "$DEST"/*.itb >/dev/null 2>&1; then
    for f in "$DEST"/*.itb; do
      printf '  %-46s %10s bytes\n' "$(basename "$f")" "$(stat -c%s "$f")" >>"$R"
    done
  else
    echo "  未找到任何 .itb 镜像" >>"$R"
  fi

  echo "" >>"$R"; echo "[2] SHA256" >>"$R"
  if [ -f "$DEST/SHA256SUMS.mirror" ]; then cat "$DEST/SHA256SUMS.mirror" >>"$R"; fi

  echo "" >>"$R"; echo "[3] target / profile 核对" >>"$R"
  cd "$WORK/ponwrt" 2>/dev/null || true
  chk "CONFIG_TARGET_BOARD=airoha"        "grep -q '^CONFIG_TARGET_BOARD=\"airoha\"' .config"
  chk "CONFIG_TARGET_SUBTARGET=an7581"    "grep -q '^CONFIG_TARGET_SUBTARGET=\"an7581\"' .config"
  chk "只选中 1 个设备 profile"            "[ \"\$(grep -c '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_.*=y' .config)\" = 1 ]"
  chk "选中设备为 znxt_zn515xg-d"          "grep -q '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_znxt_zn515xg-d=y' .config"
  chk "镜像文件名含 zn515xg-d"             "ls $DEST/*zn515xg-d*.itb"

  echo "" >>"$R"; echo "[4] 必需能力包核对（CONFIG_PACKAGE_*=y）" >>"$R"
  for p in luci-app-pon airoha-ponctl ppp ppp-mod-pppoe kmod-pppoe \
           odhcp6c odhcpd-ipv6only dnsmasq-full firewall4 kmod-nft-nat \
           kmod-tun kmod-nft-tproxy luci-app-iptv igmpproxy luci \
           luci-i18n-base-zh-cn dropbear kmod-8021q ip-full; do
    chk "包含 $p" "grep -q '^CONFIG_PACKAGE_${p}=[ym]' .config"
  done

  echo "" >>"$R"; echo "[5] 代理插件（编入但默认不启动）" >>"$R"
  chk "luci-app-passwall2 已编入"     "grep -q '^CONFIG_PACKAGE_luci-app-passwall2=[ym]' .config"
  chk "luci-app-openclash 已编入"     "grep -q '^CONFIG_PACKAGE_luci-app-openclash=[ym]' .config"
  chk "PassWall v1 未被编入（已替换为 v2）" "! grep -q '^CONFIG_PACKAGE_luci-app-passwall=[ym]' .config"
  chk "PassWall2 走 nftables 透明代理（fw4）" "grep -q '^CONFIG_PACKAGE_luci-app-passwall2_Nftables_Transparent_Proxy=y' .config"
  chk "PassWall2 未拉入 sing-box（lean 策略）" "! grep -q '^CONFIG_PACKAGE_sing-box=[ym]' .config"
  chk "overlay 含关闭自启脚本"        "test -f files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart"

  echo "" >>"$R"; echo "[6] 运营商参数不得写死（应全为空/未设置）" >>"$R"
  for k in loid loid_password serial_number ploam_password; do
    v="$(grep -E "^\s*option\s+${k}\s+" package/feeds/pon_userspace/airoha-ponctl/files/pon.config 2>/dev/null || true)"
    printf '  pon.config %-16s -> %s\n' "$k" "${v:-<未找到>}" >>"$R"
  done

  echo "" >>"$R"
  echo "==============================================================" >>"$R"
  printf ' 汇总：PASS=%d  FAIL=%d\n' "$ok" "$bad" >>"$R"
  echo " 注意：编译成功 != 实机验证成功。未上机验证项见 刷机说明.md 第 9 节。" >>"$R"
  echo "==============================================================" >>"$R"

  cat "$R"
}

install_deps
fetch_source
setup_feeds
make_config
apply_files
compile
collect
verify
