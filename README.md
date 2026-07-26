# MB-Singbox

面向 Linux VPS 的轻量 Sing-box 管理器。当前版本 `0.2.0` 重点解决三件事：生成可被真实 Sing-box 内核接受的服务端配置、生成完整且防 DNS 泄漏的 Windows 桌面端配置、稳定输出分享链接和二维码。

项目不捆绑订阅服务器、WARP、流媒体解锁或其他与节点管理无关的功能。所有配置变化都先生成候选文件，逐份执行 `sing-box check`；服务端和任意桌面配置有一份失败，就不会替换现有产物。服务启动失败会恢复上一份状态和配置。

## 第一版范围

支持以下服务端节点，可同时运行多个：

- VLESS-Reality-Vision，TCP，无需证书。
- Hysteria2 + Salamander，UDP，需要 TLS 证书。
- TUIC v5，UDP，需要 TLS 证书。
- AnyTLS，TCP，需要 TLS 证书。
- VMess-WebSocket-TLS，TCP，需要 TLS 证书。

每个节点会生成：

- Windows 官方 Sing-box 完整 TUN 配置。
- Windows 官方 Sing-box 完整系统代理配置。
- 标准或主流兼容分享链接。
- 终端二维码和 PNG 二维码。

还会生成包含全部直连节点及可用 Argo 节点的 Windows 汇总配置。

第一版客户端以 Windows 桌面端为主。HomeProxy、Nikki 和 Momo 的专用导出不在本版范围内；其中 HomeProxy 使用 Sing-box 配置模型，而 Nikki/Momo 使用 Mihomo 配置模型，不能用同一份 JSON 假装兼容。

## 系统要求

- 使用 systemd 的 Linux VPS。
- Debian/Ubuntu 或使用 DNF/YUM 的常见发行版。
- CPU：amd64、arm64、armv7 或 386。
- root 权限。
- VPS 能访问 GitHub Release 和 Sing-box 官方资源。

内核下载只接受 GitHub 正式 Release。脚本从 Release 元数据读取资产 SHA-256 摘要，校验通过后才安装。不会自动安装 `alpha`、`beta` 或其他预发布版本。

## 一行安装

推荐先下载再执行：

```bash
curl -fsSLo /tmp/mb-singbox-install.sh https://raw.githubusercontent.com/BBMCoin04/mb-singbox/main/install.sh && sudo bash /tmp/mb-singbox-install.sh
```

快速方式：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMCoin04/mb-singbox/main/install.sh | sudo bash
```

重新打开菜单：

```bash
sudo mb-singbox
```

安装器只安装管理器。进入菜单后选择“安装/更新”，再安装 Sing-box 最新稳定版。MB-Singbox 使用自己的内核路径和 systemd 服务，不覆盖系统已有的 `/usr/bin/sing-box` 或官方 `sing-box.service`。

## 推荐部署顺序

1. 先安装并运行 MB-ACME，部署需要的 TLS 证书。
2. 安装 MB-Singbox。
3. 菜单选择 `1 -> 1`，安装 Sing-box 最新稳定版。
4. 菜单选择 `2`，设置 VPS 公网 IP/域名并创建节点。
5. TLS 协议从 `/etc/acme/certs/<域名>/` 中选择证书。
6. 菜单选择 `3`，取得 Windows 配置、分享链接和二维码。
7. 需要时在系统工具中配置 UFW、启用 BBR 或检查 AI 服务连通性。
8. IP 不可达且已经创建 VMess-WS 时，再配置 Argo 应急入口。

## 菜单

```text
1. 安装/更新
2. 创建节点
3. 查看节点、桌面配置与分享链接
4. 修改节点配置
5. 删除节点
6. 服务管理与日志
7. Argo 应急隧道（VMess-WS 专属）
8. BBR、UFW 与 AI 检测
9. 修改客户端连接地址
10. 彻底卸载
0. 退出
```

节点端口默认给出建议值，但允许手动输入。脚本分别检查 TCP 和 UDP 占用，所以 TCP 443 与 UDP 443 可以共存；同一传输类型的端口不能冲突。查看、修改和删除节点都使用编号选择，不需要手动输入长节点 ID；所有嵌套菜单中的 `0` 均表示返回。

## 配置与状态

```text
/etc/mb-singbox/state.json                    唯一状态源
/etc/mb-singbox/server.json                   当前服务端配置
/etc/mb-singbox/clients/<节点>-windows-tun.json
/etc/mb-singbox/clients/<节点>-windows-system-proxy.json
/etc/mb-singbox/clients/windows-all-tun.json
/etc/mb-singbox/clients/windows-all-system-proxy.json
/etc/mb-singbox/links/<节点>.txt
/etc/mb-singbox/links/all.txt
/etc/mb-singbox/qrcodes/<节点>.png
/etc/mb-singbox/backups/                       变更前备份
```

状态、配置和客户端文件包含节点凭据，默认只有 root 可读。Reality 私钥只存在于状态和服务端配置中，不会写入客户端、链接或二维码。

Windows TUN 配置同时提供本地 `mixed` 代理端口 `127.0.0.1:2080`；系统代理配置会在启动时设置系统代理，在停止时清理。配置使用 Sing-box 1.13 的新 DNS、路由和 TUN 字段，不使用旧 GeoIP/Geosite、旧 DNS server 格式或仅属于 1.14 预发布版的字段。

默认桌面端规则采用保守、可解释的分流：

- 先执行新式 `sniff`，再用 `hijack-dns` 接管 DNS。
- 私有 IP、局域网域名、中国域名和中国 IP 直连。
- 其他流量默认走 `proxy` selector。
- 中国域名使用阿里 DoH 直连解析。
- 其他域名使用 Cloudflare DoH，并强制经 `proxy` 查询，减少 DNS 污染和泄漏。
- 中国规则使用 SagerNet 官方 `geosite-cn.srs`、`geoip-cn.srs` 二进制远程规则集，每天更新。
- 开启 cache file 缓存远程规则集，避免每次启动重复下载。
- 支持 Clash `rule`、`global`、`direct` 模式切换。
- TUN 使用 `mixed` 栈、`auto_route` 和 `strict_route`，在 Windows 上兼顾 TCP 性能、UDP 兼容和 DNS 防泄漏。

默认不启用广告拦截、激进 MTU、UDP 分片或 MPTCP。这些选项并非越多越快，容易误伤应用或降低复杂网络下的稳定性。

## MB-ACME 联动

MB-Singbox 自动发现：

```text
/etc/acme/certs/<域名>/fullchain.pem
/etc/acme/certs/<域名>/key.pem
```

选择证书时会检查：

- 文件存在且非空。
- 证书和私钥均可被 OpenSSL 解析。
- 证书公钥与私钥匹配。

也可以手动输入其他证书的绝对路径。MB-Singbox 不直接读取 `/root/.acme.sh`，也不维护第二套 ACME 流程。

如果证书由 MB-ACME 续期，建议在 MB-ACME 中把 reload 服务设为：

```text
mb-singbox
```

## Windows 桌面端

每个节点有两份独立配置：

- `*-windows-tun.json`：适合全局接管，通常需要管理员权限。
- `*-windows-system-proxy.json`：提供 HTTP/SOCKS 混合代理并自动设置系统代理，不接管不遵循系统代理的软件。

汇总配置使用 `selector` 出站，默认选择第一项。配置含完整的 `log`、`dns`、`inbounds`、`outbounds`、`route` 和 Clash API 控制端口，不是只有代理出站的残缺片段。

将 JSON 作为一个独立配置导入 Windows 官方 Sing-box 客户端。不同配置不要同时启动，否则本地 TUN、`2080` 或 `9090` 端口会冲突。

## Argo 应急入口

普通 Cloudflare Tunnel 不能透明承载 Reality、Hysteria2、TUIC 或 AnyTLS。MB-Singbox 只允许把 Argo 绑定到 VMess-WebSocket 节点，并额外创建一个仅监听 `127.0.0.1` 的无 TLS 源站入站。

支持：

- Named Tunnel：固定域名，适合长期备用。需要 Tunnel Token 和公网主机名。
- Quick Tunnel：随机 `trycloudflare.com` 域名，适合临时救急。

Named Tunnel 默认提供自动配置流程。除 Tunnel Token 外，自动化需要一个最小权限 Cloudflare API Token：

```text
Account -> Cloudflare Tunnel -> Edit
Zone    -> DNS -> Edit
```

脚本会从 Tunnel Token 解出 Account ID 和 Tunnel ID，保留该 Tunnel 已有的其他 ingress，再创建或更新：

```text
Public Hostname -> http://127.0.0.1:<Argo 源站端口>
DNS CNAME       -> <Tunnel ID>.cfargotunnel.com
```

API Token 只在内存中用于本次请求，不写入状态、文件、日志或命令行参数；Tunnel Token 保存到 root 可读文件。自动配置后脚本会发起真实 WebSocket Upgrade 检查，只有得到 HTTP `101` 才把 Argo 标记为“已验证”。DNS 尚未生效或路由错误时，只显示“本地连接器运行、公网待验证”，不会提前宣告完成。

没有 API Token 时仍可手动配置，并在 Argo 菜单中选择“验证 Argo 公网 WebSocket”。停用或卸载只删除本机 cloudflared 服务和 Tunnel Token，不删除 Cloudflare 账户里的远程 Tunnel、ingress 或 DNS 记录。

Argo 牺牲性能换取备用可达性，不应代替 IP 正常时的直连节点。

## UFW

UFW 与 Windows 环回无关，它是 VPS 的入站防火墙。

MB-Singbox 可以：

- UFW 未安装时询问是否安装。
- 启用 UFW 前先检测并放行 SSH 端口。
- 为 Reality、AnyTLS、VMess 开放 TCP。
- 为 Hysteria2、TUIC 开放 UDP。
- 节点增删或改端口后同步自己的规则。
- 停止管理或卸载时只删除带 `MB-Singbox` 注释的规则。

云厂商安全组或 Vultr Firewall 仍需在控制台单独放行，UFW 不能替代云防火墙。

## BBR

BBR 是 Linux 内核 TCP 拥塞控制，不属于 Sing-box 内核。

脚本只在当前内核已经支持 BBR 时写入：

```text
/etc/sysctl.d/99-mb-singbox-bbr.conf
```

关闭或卸载时删除该文件并重新加载系统原有 sysctl 配置，不替换内核。BBR 主要作用于 Reality、AnyTLS、VMess 等 TCP 流量，不直接加速 Hysteria2/TUIC 的 QUIC 拥塞控制。

## AI 可用性检测

检测 ChatGPT、OpenAI API、Gemini 和 Claude 的 HTTPS 出口连通性，并报告 HTTP 状态。结果只用于诊断，不保证账号一定可用，也不会通过 WARP 或代理自动改变 VPS 出口。

AI 服务能否使用主要取决于 VPS IP 的地区、信誉和服务方策略。

## 更新与回滚

从 `0.1.0` 首次升级到 `0.2.0` 时，建议重新运行新版 `install.sh`，因为 `0.1.0` 的菜单更新流程存在退出问题。安装器只替换管理器，不删除状态、节点、内核或证书。升级后执行：

```bash
sudo mb-singbox render
```

该命令会从现有状态重新生成服务端和全部桌面配置，逐份校验，应用服务端安全/性能字段并重启；失败会恢复旧状态和配置。

更新内核时：

1. 下载指定正式版本。
2. 校验 Release SHA-256 摘要。
3. 使用新内核检查当前服务端配置。
4. 检查失败则拒绝替换。
5. 替换后重启失败则恢复旧内核。

修改节点时：

1. 从 `state.json` 生成候选服务端配置。
2. 使用当前 Sing-box 执行 `check`。
3. 生成完整桌面配置和链接。
4. 使用当前 Sing-box 逐份检查所有桌面 JSON。
5. 备份当前状态与服务端配置。
6. 原子替换并重启。
7. 服务启动失败则恢复上一版。

常用 CLI：

```bash
sudo mb-singbox install-core
sudo mb-singbox install-core 1.13.14
sudo mb-singbox check
sudo mb-singbox render
sudo mb-singbox status
sudo mb-singbox update-manager
```

## 彻底卸载

菜单中的彻底卸载需要两次确认。会删除：

- MB-Singbox 管理器、私有 Sing-box/cloudflared 二进制。
- `mb-singbox.service` 和本地 Argo 服务。
- 状态、服务端配置、桌面配置、链接、二维码、备份和日志。
- 带 `MB-Singbox` 注释的 UFW 规则。
- MB-Singbox 创建的 BBR sysctl 文件。

不会删除：

- MB-ACME。
- `/etc/acme/certs` 中的证书。
- Cloudflare 远程 Named Tunnel。
- 系统其他 UFW、sysctl 或软件包。

## 开发回归

仓库内的回归脚本会下载并校验 Sing-box `1.13.14`，生成临时自签名证书和五协议测试状态，然后检查服务端、每节点桌面配置、汇总配置、现代 DNS/路由规则、远程规则集、分享链接数量及 Reality 私钥隔离：

```bash
sudo apt-get install -y curl jq openssl tar
./tests/regression.sh
./tests/behavior.sh
```

`behavior.sh` 还会模拟菜单返回、旧状态迁移、编号选点、Cloudflare ingress/DNS 自动配置、WebSocket `101` 验证和管理器原子更新。所有测试文件都位于 `/tmp`，结束后自动删除，不修改系统服务或真实 Cloudflare 资源。
