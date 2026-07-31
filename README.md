# MB sing-box 管理器

面向 Linux VPS 的 sing-box 节点管理脚本，当前版本：`0.7.3`。

它通过菜单完成内核安装、节点管理、客户端配置、服务日志、防火墙、BBR、Hysteria2 端口跳跃和 Cloudflare Tunnel 管理。主命令是 `mb-singbox`，旧命令 `singbox` 仅用于兼容。

## 支持的节点

| 节点 | 默认端口 | 是否需要证书 |
|---|---:|---|
| VLESS + REALITY + Vision | `443/TCP` | 否 |
| Hysteria2 + Salamander | `443/UDP` | 是 |
| AnyTLS | `8443/TCP` | 是 |
| TUIC v5 | `8443/UDP` | 是 |
| VMess + WebSocket + TLS | `2087/TCP` | 是 |
| VMess + Cloudflare Tunnel | `2096/TCP` | 使用 Cloudflare 域名 |

TCP 和 UDP 端口互不冲突，例如 `443/TCP` 和 `443/UDP` 可以同时使用。

## 使用条件

- 使用 systemd 的 Debian、Ubuntu、CentOS、Rocky Linux 或 AlmaLinux VPS
- root 权限
- sing-box 服务端内核 `1.13.0+`
- 官方 sing-box Desktop 客户端 `1.14.0+`
- 云厂商安全组已放行节点端口

Hysteria2、AnyTLS、TUIC 和 VMess-TLS 需要受系统信任的证书。建议先用 MB-ACME 部署到：

```text
/etc/acme/certs/你的域名/fullchain.pem
/etc/acme/certs/你的域名/key.pem
```

不要把证书放在 `/root` 或 `/home`。证书文件更新后由 sing-box 自动重新加载，无需设置额外的 reload 命令。

## 安装

在线安装：

```bash
curl -fsSLo /tmp/mb-singbox-install.sh \
  "https://raw.githubusercontent.com/BBMCoin04/mb-singbox/main/install.sh?ts=$(date +%s)"
sudo bash /tmp/mb-singbox-install.sh
```

从 ZIP 解压安装：

```bash
sudo bash install.sh
```

本地安装时，`install.sh` 会优先使用同目录的 `mb-singbox.sh`。安装器会检查版本和脚本语法，不会覆盖其他程序，也不会用旧版本覆盖新版本。

安装后打开菜单：

```bash
sudo mb-singbox
```

## 第一次使用

1. 选择 `1 -> 1`，安装最新稳定版 sing-box 内核。
2. 选择 `2`，输入 VPS 公网 IP 或域名并创建节点。
3. 选择 `8 -> 3` 设置防火墙。不了解 UFW 时，可先选“宽松模式”。
4. 在云厂商控制台放行节点使用的 TCP/UDP 端口。
5. 选择 `3` 查看分享链接和客户端文件。

## 客户端文件

```text
/etc/mb-singbox/clients/sing-box-desktop.json
/etc/mb-singbox/clients/mihomo-nikki.yaml
/etc/mb-singbox/links/all.txt
/etc/mb-singbox/qrcodes/
```

- `sing-box-desktop.json`：用于官方 sing-box Desktop `1.14.0+`
- `mihomo-nikki.yaml`：用于 Nikki/OpenWrt 或兼容 Mihomo 的客户端
- `all.txt`：全部分享链接
- `qrcodes/`：每个节点的二维码

这些文件包含节点密码和密钥，只应由可信用户读取。

## Hysteria2 端口跳跃

创建 Hysteria2 后，进入 `4 -> 选择节点 -> 6` 开启。

- 自动模式随机使用一段连续的 1000 个 UDP 高位端口
- 服务端原端口仍保留，旧的单端口客户端仍可使用
- 脚本只管理 nftables 表 `inet mb_singbox_port_hopping`
- 开启、换范围或关闭后，必须重新导入客户端配置
- 云厂商安全组必须放行显示的完整 UDP 范围

该功能不会修改 TUIC，也不会清空系统或 Docker 的其他 nftables 规则。

## 防火墙

进入 `8 -> 3` 可选择：

- **宽松模式**：停用 UFW 和 firewalld，不清空 iptables/nftables
- **节点端口收紧模式**：UFW 默认拒绝入站，只放行识别到的 SSH 端口和当前节点端口
- **外部管理**：脚本不控制防火墙

如果无法可靠识别 SSH 端口，脚本会拒绝启用收紧模式。节点端口同步失败时会优先退回宽松模式，避免代理端口被误封。

云厂商安全组不受脚本控制，必须在云平台单独设置。不要使用 `iptables -F` 或 `nft flush ruleset`，否则可能破坏 Docker 网络。

## Cloudflare Tunnel

Argo 应急入口只能绑定 VMess-WebSocket 节点，不能用于 Reality、Hysteria2、TUIC 或 AnyTLS。

Named Tunnel 自动配置需要 Cloudflare API Token 权限：

```text
Account -> Cloudflare Tunnel -> Edit
Zone    -> DNS -> Edit
```

Token 只在本次配置中使用。停用或卸载只删除 VPS 本地服务，不会删除 Cloudflare 账户中的 Tunnel 或 DNS 记录。

## 常用命令

```bash
sudo mb-singbox status           # 查看服务和节点
sudo mb-singbox check            # 检查服务端配置
sudo mb-singbox doctor           # 检查版本、路径和状态
sudo mb-singbox render           # 重新生成并应用配置
sudo mb-singbox install-core     # 更新 sing-box 内核
sudo mb-singbox update-manager   # 更新管理器
sudo mb-singbox version          # 查看管理器版本
```

服务与日志：

```bash
systemctl status mb-singbox --no-pager -l
journalctl -u mb-singbox -n 50 --no-pager
```

## 更新与备份

更新管理器只替换管理脚本，不会自动重建配置、重启服务、修改防火墙、修改 BBR 或调用 Cloudflare API。

节点配置修改前会创建备份，默认保留最近 20 份：

```text
/etc/mb-singbox/backups/
```

新配置检查或启动失败时，脚本会尝试恢复旧状态、服务端配置、客户端文件和 systemd 服务文件。

## 常见问题

### 服务名是什么？

```text
mb-singbox.service
```

不是 `sing-box.service`。

### 更新后仍显示旧版本

```bash
sudo mb-singbox doctor
sudo mb-singbox update-manager
type -a mb-singbox singbox
```

### 节点无法连接

依次检查：

```bash
sudo mb-singbox check
sudo mb-singbox status
journalctl -u mb-singbox -n 50 --no-pager
```

然后确认云安全组、VPS 防火墙、节点端口、证书有效期以及 VPS/客户端时间。UDP 节点延迟显示 `-1` 不一定代表不可用，应同时测试实际联网。

## 卸载

在主菜单选择 `11`，按提示输入确认文字。

卸载会删除本机节点、密钥、配置、备份、内核、服务、管理器创建的节点 UFW 规则和端口跳跃规则。它不会删除 ACME 证书、Cloudflare 远程 Tunnel/DNS，也会保留已有的 SSH 放行规则，避免远程失联。
