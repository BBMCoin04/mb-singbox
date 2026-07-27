# MB-Singbox

MB-Singbox 是一个面向 systemd Linux VPS 的 Sing-box 节点管理脚本。当前管理器版本：`0.4.2`。

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
- Sing-box `1.13.0` 或更高版本
- 创建 Hysteria2、TUIC、AnyTLS、VMess 前，需要准备受系统信任的 TLS 证书
- 证书建议放在 `/etc/acme/certs/<域名>/`，不要放在 `/root` 或 `/home`

Reality 不需要证书。

## 安装

推荐先下载再执行：

```bash
curl -fsSLo /tmp/mb-singbox-install.sh \
  "https://raw.githubusercontent.com/BBMCoin04/mb-singbox/main/install.sh?ts=$(date +%s)"
sudo bash /tmp/mb-singbox-install.sh
```

安装完成后运行：

```bash
sudo singbox
```

如果从 ZIP 解压安装，可以直接执行：

```bash
sudo bash install.sh
```

安装器会优先使用同目录中的 `mb-singbox.sh`。

## 首次使用

1. 进入菜单 `1`，安装最新稳定版 Sing-box。
2. 进入菜单 `2`，填写 VPS 公网 IP 或域名并创建节点。
3. 在 VPS 防火墙和云厂商安全组中放行节点端口。
4. 进入菜单 `3`，查看分享链接和客户端配置路径。
5. 把客户端 JSON 下载到对应设备，或扫描二维码导入节点。

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

## 菜单

```text
1.  安装/更新
2.  创建节点
3.  查看节点、客户端配置与分享链接
4.  修改节点配置
5.  删除节点
6.  服务管理与日志
7.  Argo 应急隧道
8.  BBR、UFW 与 AI 检测
9.  修改客户端连接地址
10. 客户端与 VMess/Argo 优选地址
11. 彻底卸载
0.  退出
```

嵌套菜单中的 `0` 表示返回。

## 常用命令

```bash
sudo singbox version          # 查看管理器版本
sudo singbox doctor           # 检查版本、安装路径和命令冲突
sudo singbox status           # 查看服务和节点状态
sudo singbox check            # 检查服务端配置
sudo singbox render           # 重新生成并应用全部配置
sudo singbox update-manager   # 更新管理器
sudo singbox install-core     # 更新 Sing-box 内核
```

服务名称是 `mb-singbox.service`：

```bash
systemctl status mb-singbox --no-pager -l
journalctl -u mb-singbox -n 50 --no-pager
```

## 客户端文件

```text
/etc/mb-singbox/clients/sing-box-windows-tun.json
/etc/mb-singbox/clients/sing-box-windows-system-proxy.json
/etc/mb-singbox/clients/sing-box-router-tun.json
/etc/mb-singbox/links/all.txt
/etc/mb-singbox/qrcodes/
```

- Windows TUN：全局接管流量
- Windows 系统代理：只代理使用系统代理的软件
- Router TUN：适合直接运行原生 Sing-box 的 Linux/OpenWrt

不同 Windows 配置不要同时运行，否则本地端口可能冲突。

## Argo

Cloudflare Tunnel 只能绑定 VMess-WebSocket 节点，不能转发 Reality、Hysteria2、TUIC 或 AnyTLS。

Named Tunnel 自动配置需要 Cloudflare API Token 权限：

```text
Account -> Cloudflare Tunnel -> Edit
Zone    -> DNS -> Edit
```

Token 只在当前配置过程中使用，不写入状态或日志。停用或卸载只删除 VPS 本地服务，不删除 Cloudflare 账户中的 Tunnel 和 DNS。

## 更新与备份

从 `0.3.x` 更新到 `0.4.2` 会保留节点、UUID、密码、Reality 密钥、证书路径和 Argo 配置。

脚本修改配置前会执行校验并创建备份，默认保留最近 20 份：

```text
/etc/mb-singbox/backups/
```

新配置启动失败时会自动恢复旧状态、服务端配置和客户端文件。

## 常见问题

### GitHub 已更新，但 VPS 仍显示旧版本

```bash
sudo singbox doctor
type -a singbox mb-singbox
sudo singbox update-manager
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
sudo singbox check
sudo singbox render
journalctl -u mb-singbox -n 50 --no-pager
```

然后从菜单重新导出节点，删除客户端旧节点后重新导入。VPS 与客户端时间也必须准确。

### Hysteria2/TUIC 延迟显示 `-1`

UDP、QUIC、TUN 或软路由环境可能导致延迟测试不准确。请同时检查实际网页访问和服务端日志，并确认云安全组已放行对应 UDP 端口。

## 卸载

在主菜单选择 `11`，并按提示二次确认。

卸载会删除本机节点、密钥、客户端配置、备份、内核和服务。不会删除 ACME 证书，也不会删除 Cloudflare 远程 Tunnel/DNS。
