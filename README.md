# MB sing-box 管理器

MB sing-box 管理器是一个面向 systemd Linux VPS 的 sing-box 节点管理脚本。当前管理器版本：`0.5.2`。

命名约定：`MB` 只作为项目系列前缀，不另行展开；用户界面统一使用“MB sing-box 管理器”，技术标识统一使用 `mb-singbox`，上游内核统一写作 `sing-box`。主命令是 `mb-singbox`；旧命令 `singbox` 仅作为兼容别名保留。

支持以下服务端节点：

- VLESS + REALITY + Vision
- Hysteria 2 + Salamander
- AnyTLS
- TUIC v5
- VMess + WebSocket + TLS
- VMess + Cloudflare Tunnel 应急入口

## 使用要求

- Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux 等使用 systemd 的 Linux VPS
- root 权限
- VPS 服务端支持 sing-box `1.13.0` 或更高版本
- Desktop 客户端配置要求 sing-box `1.14.0` 或更高版本
- 创建 Hysteria2、TUIC、AnyTLS、VMess 前，需要准备受系统信任的 TLS 证书
- 证书建议放在 `/etc/acme/certs/<域名>/`，不要放在 `/root` 或 `/home`

Reality 不需要证书。新建 Reality 节点的默认握手域名是 `apple.com`，创建时仍会执行临时端到端兼容性校验，也可以手动输入其他域名。升级不会修改现有 Reality 节点的握手域名和客户端配置。

## 安装

推荐先下载再执行：

```bash
curl -fsSLo /tmp/mb-singbox-install.sh \
  "https://raw.githubusercontent.com/BBMCoin04/mb-singbox/main/install.sh?ts=$(date +%s)"
sudo bash /tmp/mb-singbox-install.sh
```

安装完成后运行：

```bash
sudo mb-singbox
```

旧命令 `sudo singbox` 仍可使用，但新文档统一使用 `mb-singbox`。

如果从 ZIP 解压安装，可以直接执行：

```bash
sudo bash install.sh
```

安装器会优先使用同目录中的 `mb-singbox.sh`。

## 首次使用

1. 进入菜单 `1`，安装最新稳定版 sing-box。
2. 进入菜单 `2`，填写 VPS 公网 IP 或域名并创建节点。
3. 进入菜单 `8 -> 3`，选择防火墙模式。节点机和 Docker 主机可选择宽松模式。
4. 在云厂商控制台确认安全组没有拦截节点端口。
5. 进入菜单 `3`，查看分享链接和客户端配置路径。
6. 把客户端 JSON 下载到对应设备，或扫描二维码导入节点。

## 默认端口

| 协议 | 端口 |
|---|---:|
| VLESS Reality | `443/TCP` |
| Hysteria 2 | `443/UDP` |
| AnyTLS | `8443/TCP` |
| TUIC | `8443/UDP` |
| VMess-WS-TLS | `2087/TCP` |
| Argo 公网入口 | `2096/TCP` |

TCP 和 UDP 是不同的端口空间，所以 `443/TCP` 与 `443/UDP` 可以同时使用。

Argo 的本地源站只监听 `127.0.0.1` 随机高位端口，不需要在 VPS 或安全组中开放本地源站端口。

## 防火墙模式

菜单 `8 -> 3` 提供三种状态：

- **宽松模式**：停用 UFW 和 firewalld，主机端口不再由它们限制。不会清空 `iptables`/`nftables`，会保留 Docker 的 NAT、转发和容器网络规则。
- **节点端口收紧模式**：使用 UFW 默认拒绝入站，保留已有 UFW 规则，并先放行当前 SSH TCP 端口和全部节点 TCP/UDP 端口。节点增删后自动同步；同步失败时按可用性优先策略自动退回宽松模式，避免节点因端口未放行而失联。
- **外部管理**：管理器不启用、不停用也不同步防火墙，由用户或其他系统负责。

宽松和收紧都会同时处理防火墙状态与节点端口策略。云厂商安全组独立于 VPS 系统防火墙，脚本无法自动修改；即使选择宽松模式，也要在云平台控制台放行需要的端口。

不要手工执行 `iptables -F` 或 `nft flush ruleset` 来实现全开放，这会破坏 Docker 网络。

## 菜单

```text
1.  安装/更新
2.  创建节点
3.  查看节点、客户端配置与分享链接
4.  修改节点配置
5.  删除节点
6.  服务管理与日志
7.  Argo 应急隧道
8.  BBR、防火墙宽松/收紧与 AI 检测
9.  修改客户端连接地址
10. 客户端与 VMess/Argo 优选地址
11. 彻底卸载
0.  退出
```

嵌套菜单中的 `0` 表示返回。

## 常用命令

```bash
sudo mb-singbox version          # 查看管理器版本
sudo mb-singbox doctor           # 检查版本、安装路径和命令冲突
sudo mb-singbox status           # 查看服务和节点状态
sudo mb-singbox check            # 检查服务端配置
sudo mb-singbox render           # 重新生成并应用全部配置
sudo mb-singbox update-manager   # 更新管理器
sudo mb-singbox install-core     # 更新 sing-box 内核
```

服务名称是 `mb-singbox.service`：

```bash
systemctl status mb-singbox --no-pager -l
journalctl -u mb-singbox -n 50 --no-pager
```

## 客户端文件

```text
/etc/mb-singbox/clients/sing-box-desktop.json
/etc/mb-singbox/links/all.txt
/etc/mb-singbox/qrcodes/
```

- Desktop TUN：供官方 sing-box for Desktop `1.14.0+` 使用，通过 IPv4 TUN 接管 TCP、UDP 和 DNS 流量
- Desktop 出站组：`auto` 自动测试全部节点；`manual` 默认使用 `auto`，也可手动固定任一节点
- Desktop DNS：使用独立 IPv4 bootstrap、国内 DoH、代理 DoH 和 IPv4 FakeIP；AAAA 查询返回空结果
- 规则集：通过独立直连 HTTP client 下载 SagerNet 官方 geosite/geoip 二进制规则的 CDN 镜像，不依赖代理组启动
- 分享输出：继续生成 `all.txt`、每个节点的单独链接和二维码

Desktop 配置不启用 Windows 系统代理，也不额外开放本地 mixed 入站。项目不再生成软路由 JSON，不向下兼容 sing-box `1.13.x`。

## Argo

Cloudflare Tunnel 只能绑定 VMess-WebSocket 节点，不能转发 Reality、Hysteria2、TUIC 或 AnyTLS。

Named Tunnel 自动配置需要 Cloudflare API Token 权限：

```text
Account -> Cloudflare Tunnel -> Edit
Zone    -> DNS -> Edit
```

Token 只在当前配置过程中使用，不写入状态或日志。停用或卸载只删除 VPS 本地服务，不删除 Cloudflare 账户中的 Tunnel 和 DNS。

## 更新与备份

从 `0.3.x`、`0.4.2`、`0.4.3`、`0.5.0` 或 `0.5.1` 更新到 `0.5.2` 会保留节点、UUID、密码、Reality 密钥、现有 Reality 握手域名、证书路径、Argo 配置和原有 `singbox` 兼容命令。首次打开菜单时会原子迁移主服务和 Argo 服务的 systemd 描述，只执行 `daemon-reload`，不会重启运行中的服务。

`0.5.2` 重新生成配置时会先备份现有客户端、链接和二维码目录，只生成 `sing-box-desktop.json`。旧的 `sing-box-router.json` 会随客户端目录替换而移除；`all.txt`、每个节点的单独链接和二维码继续生成。

脚本修改配置前会执行校验并创建备份，默认保留最近 20 份：

```text
/etc/mb-singbox/backups/
```

新配置启动失败时会自动恢复旧状态、服务端配置和客户端文件。

## 常见问题

### GitHub 已更新，但 VPS 仍显示旧版本

```bash
sudo mb-singbox doctor
type -a mb-singbox singbox
sudo mb-singbox update-manager
```

`doctor` 会显示当前执行文件、固定安装文件、SHA-256 和远端版本。

### `sing-box.service` 不存在

本项目的服务名是：

```text
mb-singbox.service
```

### Reality 出现 `processed invalid connection`

先运行：

```bash
sudo mb-singbox check
sudo mb-singbox render
journalctl -u mb-singbox -n 50 --no-pager
```

然后从菜单重新导出节点，删除客户端旧节点后重新导入。VPS 与客户端时间也必须准确。

### Hysteria2/TUIC 延迟显示 `-1`

UDP、QUIC 或 TUN 环境可能导致延迟测试不准确。请同时检查实际网页访问和服务端日志，并确认云安全组已放行对应 UDP 端口。

## 卸载

在主菜单选择 `11`，并按提示二次确认。

卸载会删除本机节点、密钥、客户端配置、备份、内核和服务。不会删除 ACME 证书，也不会删除 Cloudflare 远程 Tunnel/DNS。
