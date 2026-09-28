# 如何真正产出固件

## 为什么本机没有直接编译出 .itb

在 Windows 上无法完成 OpenWrt / ImmortalWrt 构建，实测结论：

| 检查项 | 结果 |
|---|---|
| WSL | 未安装发行版；且 wsl.exe 被本机安全策略列入黑名单，无法调用 |
| Docker / Podman | 未安装 |
| MSYS2 / Cygwin | 未安装 |
| Git-Bash 自带 make | 不存在 |
| Git-Bash 自带 perl | 不存在（scripts/feeds 是 perl 脚本，跑不了） |
| 网络出口 | 可用，但必须绕开 http_proxy=127.0.0.1:1630（该代理不通），用 no_proxy='*' |

结论：源码改造与核对已完成，编译必须放到 Linux 上执行。

## 三种跑法

### 方式 A：GitHub Actions（推荐，零本地环境）

1. 把本目录作为仓库根目录推到 GitHub：
   新建仓库（例如 zn515xg-d-ponwrt），上传本目录全部内容（含 .github/ 目录）
2. 仓库 → Actions → Build PonWrt for ZNXT ZN515XG-D → Run workflow
3. core_profile 选 lean（默认）/ none / full
4. 等待约 1.5 至 3 小时，下载 artifact：zn515xg-d-ponwrt-lean
5. 内含 *-sysupgrade.itb、SHA256SUMS、config.full、build.log

### 方式 B：本机 WSL（需先解除 wsl.exe 黑名单）

在 WorkBuddy → 安全中心 → 命令安全 → 程序黑名单里移除 wsl.exe，
然后在 Windows 终端执行 `wsl --install -d Ubuntu-24.04`，再：

    wsl
    cd /mnt/c/Users/Feng/WorkBuddy/2026-09-28-15-30-20/zn515xg-d-ponwrt
    chmod +x build.sh && ./build.sh

解除黑名单后我可以继续接手，把整条链路在本机跑完并做产物验收。

### 方式 C：任意 Linux 机器 / VPS

    git clone <你的仓库> zn515xg-d-ponwrt && cd zn515xg-d-ponwrt
    chmod +x build.sh && ./build.sh

## 配置片段说明

- zn515xg-d.seed 里若出现当前 feed 中不存在的包名（例如 ipv6helper），
  make defconfig 会静默丢弃该行，不会导致构建失败，也不会少编其他包。
- kmod-8021q / kmod-nft-nat6 / kmod-nft-socket 若有则编入，无则丢弃；
  802.1Q 与 IGMP Snooping 本身是内核内建（CONFIG_VLAN_8021Q=y、
  CONFIG_BRIDGE_IGMP_SNOOPING=y，已在 target/linux/generic/config-6.18 核实）。

## 产物验收清单（拿到镜像后逐条核对）

    cd out/<时间戳>-zn515xg-d
    sha256sum *.itb
    grep -E 'CONFIG_TARGET_BOARD|CONFIG_TARGET_SUBTARGET' config.full
    grep -E 'CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_znxt_zn515xg-d=y' config.full
    grep -c 'CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_.*=y' config.full

- target 必须为 airoha，subtarget 必须为 an7581
- CONFIG_TARGET_DEVICE_... 选中数量必须恰好为 1，且是 znxt_zn515xg-d
- 文件名含 znxt_zn515xg-d
- 后缀是 .itb（本机型不是 .bin）
- 包列表含：airoha-ponctl、ppp-mod-pppoe、odhcpd、dnsmasq-full、firewall4、
  kmod-tun、kmod-nft-tproxy、luci-app-iptv、igmpproxy、
  luci-app-passwall、luci-app-openclash
- 代理服务默认关闭（逻辑在 files/etc/uci-defaults/99-zn515xg-d-no-proxy-autostart）
