# MB-Singbox

面向 Linux VPS 的轻量 Sing-box 管理器。第一版重点解决三件事：生成可被真实 Sing-box 内核接受的服务端配置、生成完整的 Windows 桌面端配置、稳定输出分享链接和二维码。

项目不捆绑订阅服务器、WARP、流媒体解锁或其他与节点管理无关的功能。所有配置变化都先生成候选文件并执行 `sing-box check`，通过后才替换并重启；启动失败会恢复上一份状态和配置。

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

节点端口默认给出建议值，但允许手动输入。脚本分别检查 TCP 和 UDP 占用，所以 TCP 443 与 UDP 443 可以共存；同一传输类型的端口不能冲突。

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

Named Tunnel 需要在 Cloudflare Zero Trust 中把 Public Hostname 的服务指向脚本显示的：

```text
http://127.0.0.1:<Argo 源站端口>
```

Token 只保存到 root 可读文件，不进入 `state.json`。停用或卸载只删除本机 cloudflared 服务和 Token 文件，不删除 Cloudflare 账户里的远程 Named Tunnel。

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
4. 备份当前状态与服务端配置。
5. 原子替换并重启。
6. 服务启动失败则恢复上一版。

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

仓库内的回归脚本会下载并校验 Sing-box `1.13.14`，生成临时自签名证书和五协议测试状态，然后检查服务端、每节点桌面配置、汇总配置、分享链接数量及 Reality 私钥隔离：

```bash
sudo apt-get install -y curl jq openssl tar
./tests/regression.sh
```

所有测试文件都位于 `/tmp`，结束后自动删除，不修改系统服务。
