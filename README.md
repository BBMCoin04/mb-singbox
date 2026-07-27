# MB-Singbox

面向 systemd Linux VPS 的 Sing-box 节点管理器。当前版本 `0.3.2` 生成可由真实 Sing-box 内核校验的服务端配置、Windows 客户端配置、Linux/OpenWrt 软路由配置、分享链接和二维码。

脚本不捆绑订阅服务器、WARP 或流媒体解锁。状态、服务端配置和客户端配置都保存在 root 专用目录；Reality 私钥不会写入客户端文件、分享链接或二维码。

## 支持范围

服务端可以同时运行：

- VLESS + REALITY + Vision
- Hysteria 2 + Salamander
- AnyTLS
- TUIC v5
- VMess + WebSocket + TLS
- VMess + WebSocket + Cloudflare Tunnel 应急入口

最低支持 Sing-box `1.13.0`。默认只安装 GitHub 正式 Release，不安装 alpha、beta 或其他预发布版本。内核压缩包会按 Release 元数据执行 SHA-256 校验。

## 默认端口

TCP 和 UDP 是不同的传输空间，因此同一数字的 TCP/UDP 端口可以共存：

```text
443/TCP   VLESS + REALITY
443/UDP   Hysteria 2
8443/TCP  AnyTLS
8443/UDP  TUIC v5
2087/TCP  VMess-WS-TLS 直连入口
2096/TCP  VMess-WS Argo 公网边缘入口
```

`2096/TCP` 是客户端访问 Cloudflare 边缘的端口，不是 VPS 本地 Argo 源站端口。cloudflared 源站只监听随机的 `127.0.0.1:<高位端口>`，所以 UFW 和云安全组不需要开放 Argo 的 2096 入站。

所有默认端口都可以在创建节点时手动修改。脚本分别检查 TCP 和 UDP 占用。

Reality 默认握手目标是 `www.cloudflare.com:443`。创建节点或修改握手域名时，脚本会在随机回环端口临时启动服务端和客户端，执行一次真实 Reality 端到端校验；目标不兼容、无法从 VPS 访问或 Reality 校验失败时，不会写入配置。仅通过普通 `curl` 或 TLS 探测不能证明目标与 Reality 兼容。

## 安装与启动

推荐先下载再执行：

```bash
curl -fsSLo /tmp/mb-singbox-install.sh https://raw.githubusercontent.com/BBMCoin04/mb-singbox/main/install.sh
sudo bash /tmp/mb-singbox-install.sh
```

从本 ZIP 解压后运行 `sudo bash install.sh` 时，安装器优先使用同目录中的 `mb-singbox.sh`，不会重新下载 GitHub `main`。只单独下载 `install.sh` 时才会通过 HTTPS 获取主程序。

安装后使用：

```bash
sudo singbox
```

安装布局：

```text
/usr/local/sbin/mb-singbox          管理器真实文件
/usr/local/bin/singbox              快捷命令软链接
/usr/local/lib/mb-singbox/sing-box  官方 Sing-box 内核
```

`mb-singbox` 仍作为兼容命令保留。安装器不会覆盖已有的 `/usr/local/bin/singbox`；若该路径被其他程序占用，会明确报错。

systemd 单元名称是 `mb-singbox.service`，不是 `sing-box.service`：

```bash
systemctl status mb-singbox --no-pager -l
journalctl -u mb-singbox -n 100 --no-pager
```

因此，`systemctl status sing-box` 返回 `Unit sing-box.service could not be found` 不代表 MB-Singbox 内核没有运行。

## 推荐部署顺序

1. 使用 MB-ACME 或其他 ACME 工具部署 TLS 证书。
2. 安装 MB-Singbox。
3. 选择 `1 -> 1` 安装最新稳定版 Sing-box。
4. 选择 `2` 设置 VPS 公网 IP/域名并创建节点。
5. 需要时选择 `7` 配置 Argo。
6. 选择 `3` 查看分享链接和全部客户端文件路径。
7. 选择 `10` 管理并重新实测 VMess/Argo 优选地址。
8. 在 VPS 和云厂商防火墙中放行直连节点使用的 TCP/UDP 端口。

## 菜单

```text
1.  安装/更新
2.  创建节点
3.  查看节点、客户端配置与分享链接
4.  修改节点配置
5.  删除节点
6.  服务管理与日志
7.  Argo 应急隧道（VMess-WS 专属）
8.  BBR、UFW 与 AI 检测
9.  修改客户端连接地址
10. 客户端与 VMess/Argo 优选地址
11. 彻底卸载
0.  退出
```

嵌套菜单中的 `0` 均表示返回。节点查看、修改和删除使用编号选择；错误编号会重新询问。

## 配置文件

客户端始终只生成三份汇总 JSON，内容根据当前全部节点自动更新：

```text
/etc/mb-singbox/state.json
/etc/mb-singbox/server.json
/etc/mb-singbox/clients/sing-box-windows-tun.json
/etc/mb-singbox/clients/sing-box-windows-system-proxy.json
/etc/mb-singbox/clients/sing-box-router-tun.json
/etc/mb-singbox/links/<节点>.txt
/etc/mb-singbox/links/<节点>-argo.txt
/etc/mb-singbox/links/all.txt
/etc/mb-singbox/qrcodes/<节点>.png
/etc/mb-singbox/qrcodes/<节点>-argo.png
/etc/mb-singbox/backups/
```

单节点只生成分享链接和二维码，不生成单独客户端 JSON。节点增加、修改、删除或 Argo 状态变化时，三份总配置会重新生成并逐份校验。目录默认只有 root 可读，因为客户端文件包含节点凭据。

## 客户端配置

所有 JSON 都是完整 Sing-box 配置，包含：

- `log`
- 新式 `dns.servers` 和 DNS 规则动作
- 可直接运行的 `inbounds`
- 节点、selector 和 direct `outbounds`
- `sniff`、`hijack-dns` 和 rule-set 路由规则
- cache file 与 sing-box 本地控制兼容接口

脚本不生成 Clash/Mihomo YAML 或其他 Clash 类客户端配置。`experimental.clash_api` 是 sing-box 自身提供的本地控制兼容接口，仅用于 selector、连接状态和 `Rule/Global/Direct` 模式控制，不改变 JSON 的 Sing-box 格式。

配置不使用旧 `geoip/geosite` 字段、旧 DNS outbound、旧 inbound sniff、旧 TUN 地址字段或已删除的 `gso`。

默认分流行为：

- 私有地址、局域网域名、中国域名和中国 IP 直连。
- 中国域名使用阿里 DoH 直连解析。
- 其他域名使用 Cloudflare DoH，并经 selector 代理解析。
- 其他流量默认使用 `proxy` selector。
- SagerNet 官方中国域名/IP二进制规则集每天更新。

### Windows

`sing-box-windows-tun.json` 使用 TUN 全局接管，同时提供 `127.0.0.1:2080` mixed 入站。

`sing-box-windows-system-proxy.json` 设置系统代理，不接管忽略系统代理的软件。

不同配置不要同时运行，否则 TUN、2080 或 9090 本地端口会冲突。

### Linux/OpenWrt 软路由

`sing-box-router-tun.json` 使用原生 Sing-box Linux TUN：

- `auto_route: true`
- `auto_redirect: true`
- `strict_route: true`
- `stack: "system"`
- IPv4/IPv6 TUN 地址
- 私网、链路本地和组播目的网段排除
- `/tmp/mb-singbox-cache.db` 可写缓存路径
- `route.auto_detect_interface: true` 防止代理出口回环

`auto_redirect` 需要 Linux nftables。OpenWrt fw4 可与其兼容。该文件适用于直接运行原生 Sing-box 的 Linux/OpenWrt；HomeProxy 可参考 Sing-box 配置模型，但 Nikki/Momo 使用 Mihomo 模型，不能直接导入这份 JSON。

## VMess/Argo 与优选 address

普通 Cloudflare Tunnel 不能透明承载 Reality、Hysteria 2、TUIC 或 AnyTLS。脚本只允许 Argo 绑定 VMess-WebSocket 节点，并创建无 TLS 的本地回环源站。

VMess 直连/CDN入口和 Argo 客户端配置都会将四个字段分开：

```text
address/server  实际连接的优选地址
port            VMess 直连/CDN默认 2087，Argo 默认 2096
SNI             节点自己的 TLS/Argo 域名
WebSocket Host  节点自己的 TLS/Argo 域名
```

内置候选地址池：

```text
cfip.1323123.xyz
cf.877771.xyz
cloudflare.182682.xyz
www.cloudflare.com
one.one.one.one
```

生成配置时会随机抽取最多三个候选，并执行真实 TLS + WebSocket Upgrade 检查。只有在以下条件全部满足时才把候选写入 `address/server`：

1. 使用节点自己的 TLS/Argo 域名完成证书和主机名校验。
2. 通过候选地址连接 VMess 端口：直连/CDN默认 `2087/TCP`，Argo 默认 `2096/TCP`。
3. 目标 WebSocket 路径返回 HTTP `101 Switching Protocols`。

如果 2087 节点是 DNS-only VPS 直连而不是 Cloudflare 代理入口，候选地址不会通过测试，配置会保留原始 VPS 地址。Argo 候选全部失败时回退到自己的 Argo 域名。脚本不会设置 `allow_insecure`，不会把第三方域名当作 SNI，也不会手工把 `cloudflare-ech.com` 当作普通 TLS SNI。

第三方候选域名的所有者可以随时改变 DNS，因此它们只作为经过当次实测的连接地址。可以在菜单 `10` 中关闭该功能、替换候选池、恢复默认池或重新实测生成配置。

Named Tunnel 自动配置需要：

```text
Account -> Cloudflare Tunnel -> Edit
Zone    -> DNS -> Edit
```

API Token 只在当前进程内使用，不写入状态或日志。Tunnel Token 保存到 root 可读文件。脚本会保留已有 ingress，再添加自己的 Public Hostname 和 CNAME。停用或卸载只清理本机 cloudflared，不删除 Cloudflare 账户中的远程 Tunnel/DNS。

## 证书联动

脚本自动发现：

```text
/etc/acme/certs/<域名>/fullchain.pem
/etc/acme/certs/<域名>/key.pem
```

证书选择时检查文件存在、OpenSSL 可解析以及证书公钥与私钥匹配。也可以手动输入其他绝对路径。

证书续期后建议 reload：

```bash
systemctl reload mb-singbox
```

## UFW 与 BBR

UFW 管理只添加或删除带 `MB-Singbox` 注释的规则。启用 UFW 前先检测并放行 SSH 端口，然后按节点类型分别开放 TCP 或 UDP。云厂商安全组仍需单独配置。

BBR 只在当前内核已经支持时启用，并写入：

```text
/etc/sysctl.d/99-mb-singbox-bbr.conf
```

BBR 主要作用于 TCP，不直接加速 Hysteria 2/TUIC 的 QUIC 拥塞控制。

## Reality 故障定位

服务端日志出现 `REALITY: processed invalid connection` 表示 TCP 已到达监听端口，但本次 TLS 连接没有被识别为有效 Reality 会话。按以下顺序检查：

1. 使用正确的服务名确认进程和监听：`systemctl status mb-singbox`、`ss -ltnp`。
2. 运行 `singbox check`，确认当前 `/etc/mb-singbox/server.json` 可由已安装内核加载。
3. 确认 VPS 和客户端时间同步；服务端默认允许最大一分钟时间差。
4. 在菜单 `4 -> Reality 节点 -> 4` 中更换握手域名。`www.microsoft.com` 等普通 TLS 可达站点不一定适合作为 Reality 握手目标。
5. 从菜单 `3` 重新取得分享链接并在 v2rayN 中删除旧节点后重新导入，避免保留旧的 UUID、公钥或 short ID。

分享链接中的 `pbk` 来自服务端私钥对应的公钥，`sid` 与服务端 `short_id` 相同，`sni` 与握手域名相同；脚本不会把 Reality 私钥写进客户端文件。

## 更新、校验与回滚

常用命令：

```bash
sudo singbox install-core
sudo singbox install-core 1.13.14
sudo singbox check
sudo singbox render
sudo singbox status
sudo singbox update-manager
```

节点变更流程：

1. 从状态生成候选服务端配置。
2. 使用当前 Sing-box 内核执行 `check`。
3. 备份当前状态与服务端配置。
4. 生成全部桌面、软路由配置和分享信息。
5. 对每份客户端 JSON 执行 `check`。
6. 原子替换状态和配置并重启服务。
7. 写入或启动失败时恢复上一状态并重新生成旧客户端配置。

## 开发回归

```bash
./tests/behavior.sh
./tests/regression.sh 1.13.14
```

回归测试会下载并校验官方 Sing-box `1.13.14`，检查服务端、固定三份汇总桌面/软路由配置、现代 DNS/路由字段、默认端口、VMess/Argo address/SNI/Host 分离、分享链接数量以及 Reality 私钥隔离。
