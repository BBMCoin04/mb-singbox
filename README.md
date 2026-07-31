# MB sing-box 管理器

MB sing-box 管理器是一个面向 systemd Linux VPS 的 sing-box 节点管理脚本。当前管理器版本：`0.7.3`。

命名约定：`MB` 只作为项目系列前缀，不另行展开；用户界面统一使用“MB sing-box 管理器”，技术标识统一使用 `mb-singbox`，上游内核统一写作 `sing-box`。主命令是 `mb-singbox`；旧命令 `singbox` 仅作为兼容别名保留。

支持以下服务端节点：

- VLESS + REALITY + Vision
- Hysteria 2 + Salamander（可按节点开启 UDP 端口跳跃）
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

推荐先用 MB-ACME 申请并部署证书，再安装 MB sing-box。ACME 签发后的 reload 服务名留空即可；sing-box 会监视 `certificate_path` 和 `key_path`，证书文件更新后自动加载新证书，不需要 HUP、reload 或 restart。创建 TLS 节点时，脚本会扫描 `/etc/acme/certs/*/fullchain.pem`：只有一张证书时自动选中，多张证书时才要求选择。

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

安装器会优先使用同目录中的 `mb-singbox.sh`。安装目标必须不存在或是可识别的 MB sing-box 普通文件；不会覆盖目录、软链接或其他程序，也不会用较低版本覆盖已安装的较高版本。安装被 `HUP`、`INT` 或 `TERM` 中断时，会恢复原管理器和快捷链接。

## 首次使用

1. 进入菜单 `1`，安装最新稳定版 sing-box。
2. 进入菜单 `2`，填写 VPS 公网 IP 或域名并创建节点。
3. 进入菜单 `8 -> 3`，选择防火墙模式。节点机和 Docker 主机可选择宽松模式。
4. 在云厂商控制台确认安全组没有拦截节点端口。
5. 进入菜单 `3`，查看分享链接和客户端配置路径。
6. Desktop 使用 JSON；Nikki/OpenWrt 使用 `mihomo-nikki.yaml`；也可以扫描二维码导入单节点。

## 默认端口

| 协议 | 端口 |
|---|---:|
| VLESS Reality | `443/TCP` |
| Hysteria 2 | `443/UDP`（端口跳跃默认关闭） |
| AnyTLS | `8443/TCP` |
| TUIC | `8443/UDP` |
| VMess-WS-TLS | `2087/TCP` |
| Argo 公网入口 | `2096/TCP` |

TCP 和 UDP 是不同的端口空间，所以 `443/TCP` 与 `443/UDP` 可以同时使用。

Argo 的本地源站只监听 `127.0.0.1` 随机高位端口，不需要在 VPS 或安全组中开放本地源站端口。

## Hysteria2 端口跳跃

Hysteria2 创建时仍使用单端口。需要时进入菜单 `4 -> 选择 Hysteria2 节点 -> 6` 手动开启，不影响 TUIC 或其他协议。

- 自动开启会从 `20000-59999` 随机选择 1000 个连续 UDP 端口，跳跃间隔固定为 30 秒
- 也可以输入自定义连续端口范围，脚本会检查现有 UDP 节点、其他跳跃范围和系统监听端口冲突
- sing-box 服务端继续监听节点原端口，独立的 `mb-singbox-port-hopping.service` 使用项目专属 nftables table 将跳跃范围转发到该端口
- 开启、重新随机或关闭成功后，会自动刷新 Desktop JSON、Mihomo/Nikki YAML、V2rayN `mport` 分享链接、`all.txt` 和二维码
- 输出目录只保留当前有效版本；关闭后配置和分享链接自动恢复单端口，不同时保留两套配置
- VPS 上的输出会自动刷新，但已导入客户端的配置不会自动变化；每次调整后需要重新导入或下载配置
- V2rayN 建议为 Hysteria2 选择 sing-box 内核；部分 Xray 版本使用 `mport` 时可能无法联网

首次开启时如果缺少 `nft`，脚本会安装 nftables，但不会主动启用或覆盖系统的全局 nftables 配置。脚本只维护 `table inet mb_singbox_port_hopping`，停止主服务、关闭端口跳跃、删除节点和卸载时都会清理对应规则。转发规则带有 `counter` 便于排障；检测到 `iptables-legacy` 时会提醒实际验证 UDP 连通性。

云厂商安全组无法由脚本修改。开启后必须在云控制台放行菜单显示的完整 UDP 范围；服务端原始 `443/UDP` 入口仍会保留，旧的单端口客户端可继续使用，但刷新后的端口跳跃配置必须能够访问完整范围。

## 防火墙模式

菜单 `8 -> 3` 提供三种状态：

- **宽松模式**：停用 UFW 和 firewalld，主机端口不再由它们限制。不会清空 `iptables`/`nftables`，会保留 Docker 的 NAT、转发和容器网络规则。
- **节点端口收紧模式**：使用 UFW 默认拒绝入站，保留已有 UFW 规则，并先放行当前 SSH TCP 端口、全部节点 TCP/UDP 端口以及已启用的 Hysteria2 UDP 跳跃范围。缺少 UFW 时会先执行 APT 安装预演，若需要移除软件包则显示清单并再次确认；无法从当前 SSH 会话或 `sshd -T` 可靠识别 SSH 端口时拒绝收紧。节点增删或端口跳跃开关后自动同步；同步失败时按可用性优先策略自动退回宽松模式。
- **外部管理**：管理器不启用、不停用也不同步防火墙，由用户或其他系统负责。切换到外部管理或卸载时会删除管理器的节点端口规则，但为防止远程失联，保留已经创建的 SSH 放行规则。

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
/etc/mb-singbox/clients/mihomo-nikki.yaml
/etc/mb-singbox/links/all.txt
/etc/mb-singbox/qrcodes/
```

### Desktop JSON

供官方 sing-box for Desktop `1.14.0+` 使用，通过双栈 TUN 接管 IPv4、IPv6、TCP、UDP 和 DNS。

### Mihomo/Nikki YAML

主要用于 Nikki/OpenWrt，也可导入支持 Mihomo 的 Windows 客户端。只显示三个策略组：

- `自动选择`：Reality/Hysteria2 主力优先，其次 TUIC/AnyTLS，最后 Argo
- `手动选择`：手动选择任意节点
- `故障转移`：按主力、备用、Argo 顺序切换

节点输出规则：

- Reality、Hysteria2 是主力节点
- Hysteria2 自动输出 Salamander 和多端口跳跃范围
- TUIC、AnyTLS 是备用节点
- 只输出 Argo VMess 应急入口，不输出 VMess 直连
- 使用官方 MetaCubeX MRS 规则，国内和私有地址直连，其他流量进入 `手动选择`
- 默认关闭 IPv6，避免软路由 IPv6 未接管时绕过代理

Nikki 建议选择 TPROXY，并让插件接管 DNS 劫持到配置中的 `1053` 端口。WAN 不应开放 `7890`、`7892`、`7893`、`9090` 或 `1053`。YAML 内的代理认证密码和控制器密钥会首次自动生成并保持不变。

Windows 客户端可能覆写本地端口、系统代理、TUN 和控制器设置，这是正常行为。

## Argo

Cloudflare Tunnel 只能绑定 VMess-WebSocket 节点，不能转发 Reality、Hysteria2、TUIC 或 AnyTLS。

Named Tunnel 自动配置需要 Cloudflare API Token 权限：

```text
Account -> Cloudflare Tunnel -> Edit
Zone    -> DNS -> Edit
```

Token 只在当前配置过程中使用，不写入状态或日志。停用或卸载只删除 VPS 本地服务，不删除 Cloudflare 账户中的 Tunnel 和 DNS。

## 更新与备份

从旧版本更新到 `0.7.3` 会保留节点、UUID、密码、Reality 密钥、现有 Reality 握手域名、证书路径、Argo 配置和原有 `singbox` 兼容命令。管理器升级本身不会执行 `render`，不会重写服务端或客户端配置，不会重启服务，也不会修改 UFW、firewalld、nftables、BBR 或 Cloudflare 远端资源。现有 Hysteria2 节点保持原端口跳跃状态。只有旧状态确实缺少历史字段时才会在操作锁内创建迁移备份并原子补齐；已经规范化的状态不会重写。

`0.5.2` 起，重新生成配置时会先备份现有客户端、链接和二维码目录，只生成 `sing-box-desktop.json`。旧的 `sing-box-router.json` 会随客户端目录替换而移除；`all.txt`、每个节点的单独链接和二维码继续生成。

`0.5.3` 起，管理器更新优先通过 GitHub Contents API 获取分支实时文件，`raw.githubusercontent.com` 仅作为回退。远端版本与当前版本相同时只提示已是最新版，不再重复覆盖。

`0.5.4` 起，Desktop 配置使用双栈 TUN 和双栈 FakeIP，DNS 与节点域名解析采用 IPv4 优先、IPv6 回退。国内域名按 `geosite-geolocation-cn` 直连；CN IP 仅在不属于明确非 CN 域名时直连，以减少 CDN 误分流。

`0.5.5` 起，菜单更新检查会保留结果直到按 Enter。同版本检查不再重载菜单；只有实际安装新版本后才在确认后载入新版菜单。

`0.6.0` 起，Hysteria2 可以在修改节点菜单中按需开启端口跳跃。脚本自动生成或校验 UDP 范围，通过独立最小权限 systemd 服务管理 nftables 转发，并将规则、服务文件、客户端 JSON、分享链接和二维码纳入同一套备份与失败回滚流程。TUIC 保持单端口。

`0.6.1` 修复端口跳跃成功后范围提示显示为空的问题，并明确 Desktop JSON 版本提示不影响 V2rayN 分享链接；不改变已保存的端口范围或运行规则。

`0.7.0` 新增 Mihomo/Nikki YAML：按主力、备用、Argo 应急分层，支持 Hysteria2 多端口、TUIC、AnyTLS 和 Reality；VMess 只输出 Argo 应急入口。使用三个可见策略组、官方 MRS 规则、Fake-IP DNS、稳定随机认证和原子输出。

`0.7.1` 优化“重新生成并应用全部配置”：服务端内容未变化时只刷新客户端 JSON/YAML，不再重启 sing-box 或端口跳跃服务，避免代理链路中的 SSH 会话短暂掉线。

`0.7.2` 改为纯文本 IPv6 校验；Reality 临时服务改为最多等待 5 秒的端口就绪轮询；候选状态生成失败时保留原配置并直接报告；单张 MB-ACME 证书自动选中；端口跳跃增加 nftables 计数器和 iptables-legacy 告警。证书续期依赖 sing-box 对证书文件的自动热加载，不配置额外 ACME reload。脚本最低服务端版本 `1.13.0` 已包含对证书路径原子替换的持续监听修复。

`0.7.3` 完成安装、内核、状态、客户端输出和双 systemd unit 的事务回滚；操作锁改为单次修改完成后立即释放，systemd 端口跳跃子命令保持无锁；UFW 增加 APT 卸载预演和 SSH 防失联拒绝条件；BBR 关闭增加确认、备份和失败恢复；状态增加非破坏性的跨字段一致性检查；Cloudflare Named Tunnel 合并保留 path-only ingress，并在 DNS 写入失败或信号中断时尝试恢复原 ingress。升级不会主动触发这些修改路径。

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

`0.5.3` 的更新器会显示实际使用的下载源。`doctor` 会显示当前执行文件、固定安装文件、SHA-256 和远端版本。若仍在运行 `0.5.2` 或更早版本且 Raw 缓存未刷新，可重新下载最新版 `install.sh` 覆盖安装。

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

卸载会删除本机节点、密钥、客户端配置、备份、内核、服务、管理器创建的节点 UFW 规则以及 Hysteria2 端口跳跃 nftables table。为避免远程 VPS 失联，已有 SSH 放行规则会保留。不会删除 ACME 证书，也不会删除 Cloudflare 远程 Tunnel/DNS 或系统其他 nftables 规则。
