#!/usr/bin/env bash
# =============================================================================
# ZNXT ZN515XG-D (Airoha AN7581) 三网通用 PonWrt 一键构建脚本
# 代理方案：HomeProxy + OpenClash + Nikki（PassWall / PassWall2 已整体移除）
#
# 运行环境：Linux（Ubuntu 22.04/24.04 或 WSL2）。Windows 原生 Git-Bash 不支持。
#
#   ./build.sh    # 单一策略：sing-box（HomeProxy）+ mihomo-meta（Nikki / OpenClash）
#                 # 不再有 PassWall2 的 Basic_Core choice，也就没有 CORE_PROFILE 之分。
#
# 机型：同一个 SoC（Airoha AN7581），target/linux/airoha/image/an7581.mk 里
#       TARGET_DEVICES 列出的机型都可用 TARGET_DEVICE 切换：
#   TARGET_DEVICE=znxt_zn515xg-d        ./build.sh     # ZNXT ZN515XG-D（默认）
#   TARGET_DEVICE=fiberhome_hg5585f-ct  ./build.sh     # 烽火 HG5585F 电信版
#   TARGET_DEVICE=fiberhome_hg5585f-cu  ./build.sh     # 烽火 HG5585F 联通版
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
# TARGET_DEVICE 必须是 target/linux/airoha/image/an7581.mk 里 TARGET_DEVICES 之一
TARGET_DEVICE="${TARGET_DEVICE:-znxt_zn515xg-d}"
DEVICE="$TARGET_DEVICE"
DEVICE_DTS="znxt,zn515xg-d"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/${STAMP}-${TARGET_DEVICE}"

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
  for p in luci-app-homeproxy ucode-mod-digest sing-box \
           luci-app-openclash luci-app-nikki nikki mihomo-meta \
           luci-app-iptv luci-app-pon \
           igmpproxy omcproxy ruby-yaml luci-compat lyaml; do
    "$WORK/ponwrt/scripts/feeds" install "$p" >/dev/null 2>&1 || true
  done

  # 记录本次实际拉到的各 feed 版本，便于日后复现 / 对比「插件是否真更新了」
  log "记录 feeds 版本"
  : > "$DEST/feeds-revisions.txt"
  for d in "$WORK/ponwrt/feeds"/*; do
    [ -d "$d/.git" ] || continue
    printf '%-24s %s\n' "$(basename "$d")" \
      "$(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)" >> "$DEST/feeds-revisions.txt"
  done
  cat "$DEST/feeds-revisions.txt"
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
  # PassWall2 移除后不再有 Basic_Core choice（Xray / SingBox / All），
  # 也不再编 xray-core（约 15-20MB）。本版只有两个核心：
  #   sing-box    → HomeProxy（seed 第 9 节）
  #   mihomo-meta → Nikki / OpenClash（seed 第 12 / 10 节）
  # 两者由各自 LUCI_DEPENDS / DEPENDS 自动选中，此处无需追加任何符号。

  # 3.3a 兜底：关掉 sing-box 1.14 的 Naive outbound → libcronet → gn/host 链
  # 上游 net/sing-box/Makefile 写的是 def_bool y（无 prompt，.config 里写 n 也无效），
  # DEPENDS 带 +SING_BOX_BUILD_NAIVE_OUTBOUND:libcronet，GO_PKG_TAGS 还会加
  # with_naive_outbound。三处都要去掉，否则 Kconfig 强制选中 libcronet，
  # 其 PKG_BUILD_DEPENDS:=gn/host 在 CI 上编译失败，整轮 2h+ 白跑。
  #
  # 注意：feed 里的真实路径是 feeds/packages/net/sing-box/Makefile（两级目录），
  # 不能用 feeds/*/sing-box/Makefile 这种单层 glob —— 上一轮就是这样漏补丁的。
  log "关闭 sing-box Naive outbound 重依赖链"
  # 只做最小改动：def_bool y→n + 去掉两条条件 DEPENDS。
  # 不要删含 with_naive_outbound 的行！上游有
  #   ifneq ($(findstring with_naive_outbound,$(GO_PKG_TAGS)),)
  #     TARGET_LDFLAGS += -lcronet
  #   endif
  # 删掉 ifneq 会留下孤立 endif，Makefile 语法坏掉 → metadata.pl 解析失败 →
  # defconfig 把整个 sing-box 包剔除（run 43167511728 的失败点）。
  # def_bool n 后 GO_PKG_TAGS 的 $(if ...) 展开为空，findstring 自然不成立，
  # 不需要动 GO_PKG_TAGS 和那个 ifneq 块。
  PATCHED=0
  while IFS= read -r mk; do
    [ -f "$mk" ] || continue
    grep -q "SING_BOX_BUILD_NAIVE_OUTBOUND" "$mk" || continue
    BEFORE=$(grep -cE '^[[:space:]]*(ifeq|ifneq|endif|define|endef)' "$mk" || true)
    sed -i \
      -e '/config SING_BOX_BUILD_NAIVE_OUTBOUND/,+3 s/def_bool y.*/def_bool n/' \
      -e 's/+SING_BOX_BUILD_NAIVE_OUTBOUND:libcronet//g' \
      -e 's/+SING_BOX_TINY_BUILD_NAIVE_OUTBOUND:libcronet//g' \
      "$mk"
    AFTER=$(grep -cE '^[[:space:]]*(ifeq|ifneq|endif|define|endef)' "$mk" || true)
    if [ "$BEFORE" != "$AFTER" ]; then
      echo "FATAL: 补丁破坏了 ${mk} 的控制块结构（$BEFORE → $AFTER）" >&2
      exit 1
    fi
    NAIVE_DEF=$(sed -n '/config SING_BOX_BUILD_NAIVE_OUTBOUND/,+2p' "$mk" \
                | grep -m1 'def_bool' || true)
    case "$NAIVE_DEF" in
      *'def_bool y'*)
        echo "FATAL: ${mk} 的 Naive outbound 仍是 def_bool y，补丁未生效" >&2
        exit 1;;
    esac
    echo "  patched: ${mk#"$WORK/ponwrt/"}（控制块 $BEFORE 个，结构未变）"
    PATCHED=$((PATCHED + 1))
  done < <(find "$WORK/ponwrt/feeds" -type f -path '*/sing-box/Makefile' 2>/dev/null || true)
  echo "  命中 sing-box/Makefile 数：$PATCHED"
  if [ "$PATCHED" -eq 0 ]; then
    echo "  WARN: 没找到含 SING_BOX_BUILD_NAIVE_OUTBOUND 的 Makefile"
    echo "        （上游可能已移除该选项，以 defconfig 后的反向硬校验为准）"
  fi

  # 改过 Makefile 必须强制 metadata.pl 重扫，否则 tmp/.config-package.in 里
  # 仍是旧的 DEPENDS，defconfig 会照旧选中 libcronet。
  rm -f tmp/.config-package.in tmp/.config-target.in
  rm -f tmp/info/.files-packageinfo-* 2>/dev/null || true

  log "make defconfig"
  make defconfig 2>&1 | tail -20

  # 3.3b 硬校验：make defconfig 会把 feeds 里找不到的符号**静默剔除**，不报错。
  #      9-30 那版只做「验收报告」里的事后 chk，编完才发现少包已经晚了。
  #      这里对「代理 + PON + 后台升级必需组件」做致命校验，缺一个就停。
  log "defconfig 后硬校验（代理 / PON / MWAN3 / 后台升级组件）"
  REQUIRED_PACKAGES="luci-app-homeproxy ucode-mod-digest sing-box \
luci-app-openclash luci-app-nikki \
nikki mihomo-meta yq kmod-dummy \
luci-app-pon airoha-ponctl luci-app-iptv \
fitblk fit-check-sign nand-utils ubi-utils luci-mod-system luci \
luci-app-mwan3 mwan3 iptables-nft xtables-nft ip6tables-nft ipset \
iptables-mod-conntrack-extra iptables-mod-ipopt \
kmod-nft-compat kmod-ip6tables kmod-ipt-ipset kmod-ipt-conntrack-extra kmod-ipt-ipopt"
  MISSING=""
  for p in $REQUIRED_PACKAGES; do
    grep -q "^CONFIG_PACKAGE_${p}=[ym]" .config || MISSING="$MISSING $p"
  done
  if [ -n "$MISSING" ]; then
    cp -a .config "$DEST/config.full" 2>/dev/null || true
    echo "FATAL: defconfig 后以下关键符号消失（feed 版本变动 / 包名改了 / 依赖不满足）：" >&2
    echo "  $MISSING" >&2
    echo "已保存 config.full 供上传；请检查 feeds 更新日志并修正 zn515xg-d.seed 后重跑。" >&2
    echo "--- .config 中 sing-box / libcronet 相关符号 ---" >&2
    grep -E '^#? ?CONFIG_(PACKAGE_sing-box|PACKAGE_libcronet|SING_BOX.*NAIVE_OUTBOUND)' .config >&2 || true
    exit 1
  fi
  # 反向校验：不该出现的包绝不能混进 .config
  #   libcronet / naiveproxy → 触发 gn/host（run 43149817429 的失败点）
  #   legacy iptables 变体   → 与 iptables-nft 都 PROVIDES:=iptables，
  #                            两个一起装会抢 /usr/sbin/iptables 的 alternatives；
  #                            本固件是 firewall4，只应存在 nft 变体。
  #   PassWall / PassWall2 前端 → 本版整体移除，若被依赖悄悄拉回说明 feed/seed
  #                            清理不干净，必须在这里拦住。
  FORBIDDEN=""
  for p in libcronet naiveproxy iptables-zz-legacy ip6tables-zz-legacy xtables-legacy \
           luci-app-passwall luci-app-passwall2; do
    if grep -q "^CONFIG_PACKAGE_${p}=[ym]" .config; then
      FORBIDDEN="$FORBIDDEN $p"
    fi
  done
  if [ -n "$FORBIDDEN" ]; then
    cp -a .config "$DEST/config.full" 2>/dev/null || true
    echo "FATAL: 以下包不应被选中（gn/host 失败链 / legacy iptables 冲突 / 已移除的 PassWall 前端）：$FORBIDDEN" >&2
    echo "检查 sing-box 的 Naive outbound 配置、feeds/*/*/sing-box/Makefile 补丁，以及 zn515xg-d.seed 第 15 节。" >&2
    echo "--- .config 中相关符号（已保存为 config.full 供上传）---" >&2
    grep -E '^#? ?CONFIG_(PACKAGE_libcronet|PACKAGE_naiveproxy|SING_BOX.*NAIVE_OUTBOUND)' .config >&2 || true
    echo "--- 仍引用 libcronet 的 feed Makefile ---" >&2
    grep -rl 'libcronet' feeds/*/ --include=Makefile 2>/dev/null | head -10 >&2 || true
    exit 1
  fi
  echo "  Naive outbound 链状态: $(grep -E '^# CONFIG_SING_BOX_BUILD_NAIVE_OUTBOUND is not set|^CONFIG_SING_BOX_BUILD_NAIVE_OUTBOUND=y' .config | head -1 || echo '符号不存在(该 feed 版本无此选项)')"
  echo "✅ 关键包校验通过（含后台升级所需 fitblk / fit-check-sign / luci-mod-system）"

  # 软报告：seed 里声明、但被 defconfig 丢弃的非关键符号（只记录，不致命）
  DROPPED=""
  while IFS= read -r sym; do
    [ -z "$sym" ] && continue
    grep -q "^${sym}=[ym]" .config || DROPPED="$DROPPED ${sym#CONFIG_PACKAGE_}"
  done < <(grep -E '^CONFIG_PACKAGE_[A-Za-z0-9_.+-]+=y$' "$HERE/zn515xg-d.seed" \
           | sed 's/=y$//' || true)
  if [ -n "$DROPPED" ]; then
    echo "WARN: seed 中以下符号在新版 feeds 里已不存在，被 defconfig 丢弃（非致命）："
    echo "  $DROPPED"
    printf '%s\n' "$DROPPED" > "$DEST/dropped-symbols.txt"
  fi

  # 记录源码基线（workflow 是 git clone -b master --depth 1，不锁 SHA，必须留档）
  {
    echo "PONWRT_REPO=$PONWRT_REPO"
    echo "PONWRT_BRANCH=$PONWRT_BRANCH"
    echo "PONWRT_COMMIT=$(git rev-parse HEAD 2>/dev/null)"
    echo "PONWRT_LAST_COMMIT=$(git log -1 --format='%ci %s' 2>/dev/null)"
    echo "KERNEL_PATCHVER=$(grep -E '^KERNEL_PATCHVER' target/linux/airoha/Makefile 2>/dev/null)"
  } > "$DEST/ponwrt-commit.txt"
  cat "$DEST/ponwrt-commit.txt"

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
    # 保留尾部完整上下文（build-fail.log 可能几十 MB，只上传尾部），并留一份 .config
    tail -n 3000 "$DEST/build-fail.log" > "$DEST/build-fail-tail.log" 2>/dev/null || true
    cp -a .config "$DEST/config.full" 2>/dev/null || true
    {
      echo "===== 错误行（最多 60 条）====="
      # 注意：不能用 `grep | head` —— set -o pipefail 下 grep 会因 SIGPIPE 返回非 0，
      # 触发 set -e 提前退出（run 43149817429 就因此丢了「日志尾部」段、退出码变 2）。
      grep -n -m 60 -E "Error [0-9]|: error:|No such file|command not found|failed to build" \
        "$DEST/build-fail.log" 2>/dev/null || true
      echo ""
      echo "===== -j1 V=s 日志尾部 ====="
      tail -n 120 "$DEST/build-fail.log" 2>/dev/null || true
      echo ""
      echo "===== -j4 日志尾部 ====="
      tail -n 40 "$DEST/build.log" 2>/dev/null || true
    } > "$DEST/failure-summary.txt"
    cat "$DEST/failure-summary.txt"
    # build-fail.log 可能极大，只保留摘要与尾部
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

  # 后台升级能力自检：platform.sh 里 REQUIRE_IMAGE_METADATA=1，
  # 镜像没有 append-metadata 生成的结构会被 sysupgrade 直接拒绝。
  log "校验 sysupgrade 镜像 metadata 与体积"
  for img in "$DEST"/*-sysupgrade.itb; do
    [ -f "$img" ] || continue
    if ! grep -aq 'metadata_version' "$img" || ! grep -aq 'supported_devices' "$img"; then
      echo "FATAL: $(basename "$img") 缺少 sysupgrade metadata，LuCI 后台升级会被拒绝" >&2
      exit 1
    fi
    echo "✅ $(basename "$img") 带 sysupgrade metadata"
    sz="$(stat -c%s "$img")"
    echo "   体积: $sz bytes ($((sz / 1024 / 1024)) MiB)"
    # fit 卷由 U-Boot 分配，DTS 里未写死大小。9-30 基线 78.7MB 实测可刷。
    # 超过 100MiB 时给告警（不致命），提示核对 U-Boot 的 fit 卷空间。
    if [ "$sz" -gt $((100 * 1024 * 1024)) ]; then
      echo "WARN: 镜像超过 100MiB，请确认 U-Boot 分配给 fit 卷的空间足够" >&2
    fi
  done

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
    echo " AN7581 PonWrt 固件验收报告"
    echo " 生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo " target_device: $DEVICE"
    echo " 代理方案:      HomeProxy + OpenClash + Nikki（sing-box + mihomo-meta）"
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
  if ls "$DEST"/*.itb >/dev/null 2>&1; then
    for f in "$DEST"/*.itb; do
      printf '  %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")" >>"$R"
    done
  else
    echo "  未找到任何 .itb 镜像" >>"$R"
  fi

  echo "" >>"$R"; echo "[3] target / profile 核对" >>"$R"
  cd "$WORK/ponwrt" 2>/dev/null || true
  chk "CONFIG_TARGET_BOARD=airoha"        "grep -q '^CONFIG_TARGET_BOARD=\"airoha\"' .config"
  chk "CONFIG_TARGET_SUBTARGET=an7581"    "grep -q '^CONFIG_TARGET_SUBTARGET=\"an7581\"' .config"
  chk "只选中 1 个设备 profile"            "[ \"\$(grep -c '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_.*=y' .config)\" = 1 ]"
  chk "选中设备为 ${DEVICE}"          "grep -q '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_${DEVICE}=y' .config"
  chk "镜像文件名含 ${DEVICE}"         "ls $DEST/*${DEVICE}*.itb"

  echo "" >>"$R"; echo "[4] 必需能力包核对（CONFIG_PACKAGE_*=y）" >>"$R"
  for p in luci-app-pon airoha-ponctl ppp ppp-mod-pppoe kmod-pppoe \
           odhcp6c odhcpd-ipv6only dnsmasq-full firewall4 kmod-nft-nat \
           kmod-tun kmod-nft-tproxy luci-app-iptv igmpproxy luci \
           luci-i18n-base-zh-cn dropbear ip-full; do
    chk "包含 $p" "grep -q '^CONFIG_PACKAGE_${p}=[ym]' .config"
  done
  # 802.1Q 与 IGMP Snooping 是内核内建（target/linux/generic/config-* 的
  # CONFIG_VLAN_8021Q=y / CONFIG_BRIDGE_IGMP_SNOOPING=y），
  # OpenWrt 中已不存在 kmod-8021q 包，因此改判内核配置而非包。
  chk "802.1Q VLAN 内核内建"         "grep -rq '^CONFIG_VLAN_8021Q=[ym]' target/linux/generic/"
  chk "IGMP Snooping 内核内建"       "grep -rq '^CONFIG_BRIDGE_IGMP_SNOOPING=[ym]' target/linux/generic/"

  echo "" >>"$R"; echo "[5] 代理插件（三个都编入，但默认都不接管流量）" >>"$R"
  chk "luci-app-homeproxy 已编入"     "grep -q '^CONFIG_PACKAGE_luci-app-homeproxy=[ym]' .config"
  chk "HomeProxy 中文包已编入"        "grep -q '^CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=[ym]' .config"
  chk "HomeProxy 依赖 ucode-mod-digest 已编入" "grep -q '^CONFIG_PACKAGE_ucode-mod-digest=[ym]' .config"
  chk "luci-app-openclash 已编入"     "grep -q '^CONFIG_PACKAGE_luci-app-openclash=[ym]' .config"
  chk "luci-app-nikki 已编入"         "grep -q '^CONFIG_PACKAGE_luci-app-nikki=[ym]' .config"
  chk "nikki 主程序已编入"             "grep -q '^CONFIG_PACKAGE_nikki=[ym]' .config"
  chk "mihomo-meta 核心已编入"         "grep -q '^CONFIG_PACKAGE_mihomo-meta=[ym]' .config"
  chk "mihomo-alpha 未被选中（与 meta 冲突）" "! grep -q '^CONFIG_PACKAGE_mihomo-alpha=[ym]' .config"
  chk "PassWall v1/v2 前端均未编入"   "! grep -q '^CONFIG_PACKAGE_luci-app-passwall=[ym]' .config && ! grep -q '^CONFIG_PACKAGE_luci-app-passwall2=[ym]' .config"
  chk "xray-core 未编入（PassWall2 移除后无使用者）" "! grep -q '^CONFIG_PACKAGE_xray-core=[ym]' .config"
  chk "sing-box 已编入（HomeProxy 核心）" "grep -q '^CONFIG_PACKAGE_sing-box=[ym]' .config"
  chk "shadowsocks-rust 未被编入（省 CI 时间）" "! grep -q '^CONFIG_PACKAGE_shadowsocks-rust-sslocal=[ym]' .config"
  chk "nikki 依赖 yq 已编入"          "grep -q '^CONFIG_PACKAGE_yq=[ym]' .config"
  chk "nikki 依赖 kmod-dummy 已编入"  "grep -q '^CONFIG_PACKAGE_kmod-dummy=[ym]' .config"
  chk "irqbalance 已编入（多核中断均衡）" "grep -q '^CONFIG_PACKAGE_irqbalance=[ym]' .config"

  echo "" >>"$R"; echo "[5b] 出厂默认值与升级幂等是否在位" >>"$R"
  chk "overlay 含关闭自启脚本"        "test -f files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart"
  chk "overlay 含 rc.local"           "test -f files/etc/rc.local"
  chk "关闭脚本覆盖 OpenClash / Nikki" "grep -q 'openclash' files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart && grep -q 'nikki' files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart"
  chk "HomeProxy 出厂不接管（main_node 兜底）" "grep -q 'main_node' files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart"
  chk "关闭脚本有升级幂等保护"        "grep -q 'needs_firstboot_init' files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart"

  echo "" >>"$R"; echo "[5c] 卸载与代理的互斥策略（无线加速 + 不破坏代理）" >>"$R"
  chk "overlay 含 offload-switch 工具"   "test -f files/usr/sbin/offload-switch"
  chk "overlay 含 offload-guard 自启服务" "test -f files/etc/init.d/offload-guard"
  chk "overlay 含网络调优 uci-defaults"   "test -f files/etc/uci-defaults/zz-zn515xg-d-net-tuning"
  chk "offload-switch 语法正确"           "sh -n files/usr/sbin/offload-switch"
  chk "offload-guard 语法正确"            "sh -n files/etc/init.d/offload-guard"
  chk "net-tuning 语法正确"               "sh -n files/etc/uci-defaults/zz-zn515xg-d-net-tuning"
  chk "出厂默认关闭 flow offload（安全侧）" "grep -q \"flow_offloading='0'\" files/etc/uci-defaults/zz-zn515xg-d-net-tuning"
  chk "出厂开启 packet steering（不绕过 netfilter）" "grep -q \"packet_steering='1'\" files/etc/uci-defaults/zz-zn515xg-d-net-tuning"
  chk "开启 flow offload 时会拦住已启用的代理" "grep -q '拒绝开启' files/usr/sbin/offload-switch"
  chk "offload-switch 识别 HomeProxy" "grep -q 'homeproxy' files/usr/sbin/offload-switch"
  chk "offload-guard 监听 homeproxy 配置变更" "grep -q 'homeproxy' files/etc/init.d/offload-guard"

  echo "" >>"$R"; echo "[5d] LuCI 后台直接升级（sysupgrade）保障" >>"$R"
  chk "fitblk 已编入（platform_check_image 依赖）" "grep -q '^CONFIG_PACKAGE_fitblk=[ym]' .config"
  chk "fit-check-sign 已编入（RAMFS_COPY_BIN）" "grep -q '^CONFIG_PACKAGE_fit-check-sign=[ym]' .config"
  chk "luci-mod-system 已编入（备份/升级页面）" "grep -q '^CONFIG_PACKAGE_luci-mod-system=[ym]' .config"
  chk "nand-utils / ubi-utils 已编入" "grep -q '^CONFIG_PACKAGE_nand-utils=[ym]' .config && grep -q '^CONFIG_PACKAGE_ubi-utils=[ym]' .config"
  chk "overlay 含 sysupgrade.conf 保留清单" "test -f files/etc/sysupgrade.conf"
  chk "保留清单含首次启动标记" "grep -q 'zn515xg-d-firstboot' files/etc/sysupgrade.conf"
  chk "关闭自启脚本有升级幂等保护" "grep -q 'needs_firstboot_init' files/etc/uci-defaults/zz-zn515xg-d-no-proxy-autostart"
  chk "网络调优脚本有升级幂等保护" "grep -q 'APPLY_DEFAULTS' files/etc/uci-defaults/zz-zn515xg-d-net-tuning"
  chk "sysupgrade.itb 带 metadata（REQUIRE_IMAGE_METADATA=1）" "grep -aq 'metadata_version' $DEST/*-sysupgrade.itb"
  chk "源码 revision 已留档" "test -f $DEST/ponwrt-commit.txt"
  chk "feeds 版本已留档" "test -f $DEST/feeds-revisions.txt"

  echo "" >>"$R"; echo "[5e] MWAN3 多 WAN 组件（编入但默认不接管路由）" >>"$R"
  chk "luci-app-mwan3 已编入"       "grep -q '^CONFIG_PACKAGE_luci-app-mwan3=[ym]' .config"
  chk "mwan3 主程序已编入"          "grep -q '^CONFIG_PACKAGE_mwan3=[ym]' .config"
  chk "iptables-nft 已编入"         "grep -q '^CONFIG_PACKAGE_iptables-nft=[ym]' .config"
  chk "xtables-nft 已编入"          "grep -q '^CONFIG_PACKAGE_xtables-nft=[ym]' .config"
  chk "ip6tables-nft 已编入"        "grep -q '^CONFIG_PACKAGE_ip6tables-nft=[ym]' .config"
  chk "ipset 已编入"                "grep -q '^CONFIG_PACKAGE_ipset=[ym]' .config"
  chk "iptables-mod-conntrack-extra 已编入" "grep -q '^CONFIG_PACKAGE_iptables-mod-conntrack-extra=[ym]' .config"
  chk "iptables-mod-ipopt 已编入"   "grep -q '^CONFIG_PACKAGE_iptables-mod-ipopt=[ym]' .config"
  # 下面 5 个就是 LuCI 软件包页里显示「不可用」的 kmod，必须随内核一起编进来
  chk "kmod-nft-compat 已编入（原不可用）"       "grep -q '^CONFIG_PACKAGE_kmod-nft-compat=[ym]' .config"
  chk "kmod-ip6tables 已编入（原不可用）"        "grep -q '^CONFIG_PACKAGE_kmod-ip6tables=[ym]' .config"
  chk "kmod-ipt-ipset 已编入（原不可用）"        "grep -q '^CONFIG_PACKAGE_kmod-ipt-ipset=[ym]' .config"
  chk "kmod-ipt-conntrack-extra 已编入（原不可用）" "grep -q '^CONFIG_PACKAGE_kmod-ipt-conntrack-extra=[ym]' .config"
  chk "kmod-ipt-ipopt 已编入（原不可用）"        "grep -q '^CONFIG_PACKAGE_kmod-ipt-ipopt=[ym]' .config"
  chk "legacy iptables 变体未被选中（避免 alternatives 冲突）" "! grep -q '^CONFIG_PACKAGE_iptables-zz-legacy=[ym]' .config && ! grep -q '^CONFIG_PACKAGE_ip6tables-zz-legacy=[ym]' .config"
  # PonWrt base-files 的 boot 里是 ( . "./$file" ) source 执行 uci-defaults，
  # 不要求可执行位；只校验文件存在即可，避免 Windows core.filemode=false 误报。
  chk "overlay 含 mwan3 出厂默认值脚本" "test -f files/etc/uci-defaults/zz-zn515xg-d-mwan3-defaults"
  chk "mwan3 默认值脚本语法正确"     "sh -n files/etc/uci-defaults/zz-zn515xg-d-mwan3-defaults"
  chk "出厂默认禁用 mwan3 服务"      "grep -q 'disable 2>/dev/null' files/etc/uci-defaults/zz-zn515xg-d-mwan3-defaults"
  chk "mwan3 脚本有升级幂等判断"     "grep -q 'user_configured_mwan3' files/etc/uci-defaults/zz-zn515xg-d-mwan3-defaults"
  chk "sysupgrade.conf 保留 mwan3 配置" "grep -q '^/etc/config/mwan3' files/etc/sysupgrade.conf"

  echo "" >>"$R"; echo "[6] 运营商参数不得写死（应全为空/未设置）" >>"$R"
  for k in loid loid_password serial_number ploam_password; do
    v="$(grep -E "^\s*option\s+${k}\s+" package/feeds/pon_userspace/airoha-ponctl/files/pon.config 2>/dev/null || true)"
    printf '  pon.config %-16s -> %s\n' "$k" "${v:-<未找到>}" >>"$R"
  done

  echo "" >>"$R"
  echo "==============================================================" >>"$R"
  printf ' 汇总：PASS=%d  FAIL=%d\n' "$ok" "$bad" >>"$R"
  echo " 注意：编译成功 != 实机验证成功。未上机验证项见 刷机说明.md 第 11 节。" >>"$R"
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
