# Suoha V2.1.2：全新 VPS 从零部署完整教程

> 适用脚本：`suoha-v2.1.2-prefix.sh`（Suoha V2.1.2 节点前缀版）  
> 适用系统：Ubuntu、Debian、Alpine；CPU 架构：x86_64/amd64、ARM64/aarch64。  
> 推荐环境：Ubuntu 24.04 LTS、x86_64、至少 1 vCPU / 1 GB RAM / 10 GB 磁盘（这是实用建议，不是脚本硬性最低要求）。

本教程按一台全新的 VPS 编写，包含系统准备、域名和 Cloudflare 准备、脚本上传、交互式安装、端口放行、订阅导入、验证、日常维护和故障恢复。建议按顺序操作，不要跳过域名解析和防火墙检查。

---

## 一、部署前先决定使用哪种网络模式

脚本启动后会让你选择连接模式。先理解区别，再准备域名。

| 模式 | 用途 | 域名要求 | 特点 |
|---|---|---|---|
| 1. 直连 | VPS 直接提供代理节点和订阅 | 代理域名可选；若要公开 HTTPS 订阅则需要域名 | 路径最简单；代理流量不经过 Cloudflare；适合直连节点 |
| 2. Cloudflare Quick Tunnel | 通过临时 Cloudflare Tunnel 发布订阅和 Argo WS | 不要求自有订阅/Argo 域名 | 上手方便，但 `trycloudflare.com` 地址可能变化，不适合长期固定订阅 |
| 3. Cloudflare Named Tunnel | 通过自有域名发布订阅和 Argo WS | 需要 Cloudflare 托管的域名 | 地址稳定；适合长期使用和 Argo WS 节点 |

### 推荐选择

- 想要最简单、所有节点直接连接 VPS：选 **模式 1**。
- 想测试 Argo，不想准备自有域名：选 **模式 2**。
- 想长期使用自有域名、Cloudflare Tunnel 和 Argo WS：选 **模式 3**。

**重要：** Named Tunnel 只承载订阅和 Argo WebSocket 入口，不等于所有代理协议都经过 Cloudflare。脚本生成的 Reality、Hysteria2、TUIC、AnyTLS、Snell、Trojan、IPv6 Shadowsocks 等直连节点仍需要 VPS 对应端口可达。

### 域名规划建议（模式 3）

最好准备两个或三个子域名：

1. `node.example.com`：代理直连域名，A 记录指向 VPS 公网 IPv4，Cloudflare 必须设为 **DNS only（灰云）**。脚本用它申请 Let's Encrypt 证书，并生成需要 TLS 证书的直连节点。
2. `sub.example.com`：订阅域名，由脚本调用 `cloudflared tunnel route dns` 自动创建到 Named Tunnel 的路由。
3. `argo.example.com`：Argo WS 节点域名；可以与订阅域名相同，也可以单独使用。

`node.example.com` 不要开启 Cloudflare 代理（橙云），否则非 Cloudflare 支持的原始 TCP/UDP 代理端口无法按预期直连。`sub` 和 `argo` 域名由 Tunnel 接管，脚本会尝试自动创建 CNAME；不要提前手工创建冲突记录。

如果只想使用 Argo 节点、不需要直连 TLS 协议，可以在安装时把“代理连接域名”留空。但这样不会生成依赖该证书的 Hysteria2、TUIC、AnyTLS、Trojan TLS 节点；Reality 仍可使用 VPS IP，Argo 节点仍使用 Cloudflare 域名。

---

## 二、准备全新 VPS

### 1. 购买和重装系统

建议选择：

- Ubuntu 24.04 LTS 64 位；
- x86_64/amd64 或 ARM64；
- 至少 1 vCPU、1 GB RAM、10 GB 磁盘；流量较大时建议更高配置；
- 有独立公网 IPv4；如果要使用 IPv6 Shadowsocks/Snell IPv6，再确认 VPS 有可用公网 IPv6。

首次部署建议使用干净系统，不要先安装其他占用相同端口的代理服务或 Web 服务。

### 2. 首次登录

使用 VPS 服务商提供的 SSH 信息登录。Windows 可使用 Windows Terminal、PowerShell、Xshell、XTerminal 或 PuTTY。

```bash
ssh root@你的VPS公网IP
```

首次连接时核对并接受 SSH 主机指纹，然后输入 root 密码或使用 SSH 密钥。

### 3. 更新系统并检查环境

Ubuntu/Debian：

```bash
apt update
apt full-upgrade -y
reboot
```

重启后重新 SSH 登录，再检查：

```bash
cat /etc/os-release
uname -m
id
```

确认：

- 系统为 Ubuntu 或 Debian；
- `uname -m` 返回 `x86_64`、`amd64`、`aarch64` 或 `arm64`；
- 当前用户为 root（`uid=0`）。

脚本会自动安装所需依赖、sing-box、cloudflared（若选择模式 2/3 会实际使用）和服务文件。不要另外手工安装一套不同版本的 sing-box。

---

## 三、域名和 Cloudflare 准备

### A. 模式 1：直连

如果要使用域名和证书：

1. 在 DNS 服务商添加 `node.example.com` 的 A 记录，指向 VPS 公网 IPv4。
2. 如果 VPS 有公网 IPv6且准备使用，添加正确的 AAAA 记录；没有可用 IPv6就不要添加错误的 AAAA。
3. 如果使用 Cloudflare DNS，`node.example.com` 设为 DNS only（灰云）。
4. 确保公网 TCP 80 可从互联网访问，因为脚本使用 Let's Encrypt HTTP-01 standalone 方式申请证书。
5. 确保 TCP 80 当前没有被 Nginx、Apache、Caddy 等程序占用。

如果不准备域名，可在安装时把代理连接域名留空；但公开 HTTPS 订阅入口也不会生成，只能使用本机订阅地址或自行另行配置访问方式。

### B. 模式 2：Quick Tunnel

不需要事先配置自有 Tunnel 域名。安装时脚本会启动 Cloudflare Quick Tunnel，并从日志中读取 `*.trycloudflare.com` 地址。该地址可能在 Tunnel 重建后变化，客户端订阅需要跟着更新。

### C. 模式 3：Named Tunnel

准备：

- 一个已添加到 Cloudflare 账户、且当前账户有 DNS 管理权限的域名；
- `sub.example.com` 和 `argo.example.com` 两个未被其他 DNS 记录占用的子域名（可以填写同一个）；
- 能在本地浏览器打开 Cloudflare 授权页面。

安装时脚本会运行 `cloudflared tunnel login`。SSH 终端会显示授权 URL：复制到本地电脑浏览器，登录 Cloudflare 并选择对应域名所在的 Zone，授权完成后回到 VPS 继续。

随后脚本会创建名为 `suoha-v2` 的 Tunnel（如果列表里已有同名 Tunnel，会尝试复用），并自动为订阅域名和 Argo 域名创建 DNS 路由。

**新 VPS 特别注意：** 如果你的 Cloudflare 账户中已经有一个叫 `suoha-v2` 的旧 Tunnel，而新 VPS 的 `/root/.cloudflared/` 里没有该 Tunnel 对应的凭证 JSON，脚本可能会找到旧 Tunnel 却无法在新 VPS 上运行它。为了避免与旧 VPS 冲突，建议在安装前给新部署使用一个唯一 Tunnel 名称。上传脚本后、正式安装前执行下面命令，把示例名称改成自己独有的名字：

```bash
sed -i 's/local name="suoha-v2"/local name="suoha-v2-new01"/' /root/suoha-v2.1.2-prefix.sh
```

例如可用 `suoha-v2-dmit-2026`。名称只允许按 Cloudflare Tunnel 名称规则填写。确认 Cloudflare 账户中没有同名 Tunnel。若沿用旧的 `sub`/`argo` DNS 记录，先确认旧 Tunnel 已停止并处理旧 CNAME，避免 DNS 记录冲突或流量仍指向旧 VPS。不要误删账户中其他用途的 Tunnel。

---

## 四、下载并上传 Suoha V2.1.2 脚本

先从本教程对应的附件下载：`suoha-v2.1.2-prefix.sh`。

将文件上传到 VPS 的 `/root/` 目录。推荐使用 WinSCP：

1. 新建 SFTP 连接，主机填写 VPS 公网 IP，用户名 `root`，端口 `22`；
2. 登录后进入远程目录 `/root/`；
3. 将 `suoha-v2.1.2-prefix.sh` 拖入该目录。

也可以从本地电脑使用 SCP（在脚本所在的本地目录执行）：

```bash
scp ./suoha-v2.1.2-prefix.sh root@你的VPS公网IP:/root/
```

回到 VPS SSH 终端确认文件存在：

```bash
ls -lh /root/suoha-v2.1.2-prefix.sh
```

---

## 五、安装前检查脚本

执行：

```bash
chmod 700 /root/suoha-v2.1.2-prefix.sh
bash -n /root/suoha-v2.1.2-prefix.sh
```

如果 `bash -n` 没有任何输出，表示 Shell 语法检查通过。如果有报错，先停止，不要继续安装。

建议保存脚本校验值，便于日后确认文件是否被替换：

```bash
sha256sum /root/suoha-v2.1.2-prefix.sh
```

如果前面需要给 Named Tunnel 改唯一名称，应在此时完成并重新运行一次 `bash -n`。

---

## 六、运行安装程序

执行：

```bash
bash /root/suoha-v2.1.2-prefix.sh install
```

脚本会自动：

1. 识别 Ubuntu/Debian/Alpine、CPU 架构和 systemd/OpenRC；
2. 安装系统依赖；
3. 安装 sing-box 1.14.4；
4. 安装 cloudflared；
5. 创建 `suoha` 系统用户；
6. 询问节点、域名、端口和 Tunnel 设置；
7. 生成协议凭证和 sing-box 配置；
8. 创建并启动服务；
9. 生成订阅文件。

### 安装交互问题逐项说明

#### 1. 选择连接 / 域名模式

```text
1) 直连
2) Cloudflare 临时 Tunnel
3) Cloudflare Named Tunnel
```

按前面规划选择 1、2 或 3。

#### 2. 节点名称统一前缀

例如输入：

```text
DMIT-
```

生成的节点会显示为 `DMIT-Suoha-VLESS-Reality-Vision` 等。留空表示不加前缀。允许英文字母、数字、点、下划线、短横线，最多 24 个字符；不支持空格和中文。

#### 3. 代理连接域名

例如：

```text
node.example.com
```

填写前请确认 DNS 已指向 VPS，且 Cloudflare 为 DNS only。脚本会申请或复用 Let's Encrypt ECC 证书。证书申请需要公网 TCP 80 可达。

如果留空，脚本会警告：依赖可信 TLS 证书的 Hysteria2/TUIC/AnyTLS/Trojan 不会启用。Reality/Snell 等仍可按脚本条件生成。

#### 4. 端口设置

默认值建议新 VPS 先保持不变：

| 协议 | 默认端口 | 传输类型 | 备注 |
|---|---:|---|---|
| VLESS Reality Vision | 4433 | TCP | 不依赖代理域名证书 |
| VLESS Reality gRPC | 4434 | TCP | 不依赖代理域名证书 |
| Hysteria2 | 8443 | UDP | 需要代理域名和证书 |
| TUIC | 8444 | UDP | 需要代理域名和证书 |
| AnyTLS | 8445 | TCP | 需要代理域名和证书 |
| Snell | 8446 | TCP | IPv4/IPv6 按实际地址生成 |
| Trojan TLS | 8447 | TCP | 需要代理域名和证书 |
| Shadowsocks IPv6 | 8448 | TCP | 仅检测到公网 IPv6 时生成 |

脚本会检查端口格式、重复和本机占用。新 VPS 建议使用默认端口；如果端口已被占用，先查明占用服务，不要盲目覆盖。

#### 5. Cloudflare 模式额外问题

模式 1：没有额外 Tunnel 域名问题。

模式 2：脚本会创建 Quick Tunnel，等待获取临时域名。

模式 3：输入：

- Cloudflare 订阅域名，例如 `sub.example.com`；
- Argo 节点域名，例如 `argo.example.com`；如果与订阅域名相同可直接回车；
- 自定义优选 IPv4：可以留空，脚本会加入内置 Cloudflare Anycast 候选地址。也可以输入逗号分隔的 IPv4。

模式 3 后续会出现 Cloudflare 授权流程。按屏幕显示的 URL 在浏览器授权，授权成功后返回终端等待脚本完成。

#### 6. 安装完成

看到类似提示：

```text
部署完成。sing-box 配置和凭证已写入 /etc/suoha-v2
```

并输出订阅地址，表示安装流程执行到完成。仍需按后续步骤检查服务状态、配置和端口，不能只凭这一行就认定所有节点已经从客户端实测可用。

---

## 七、配置 VPS 防火墙和服务商安全组

需要同时检查两层：

1. VPS 系统防火墙（如 UFW）；
2. VPS 服务商后台的 Firewall / Security Group / 防火墙规则。

两层都要放行相应端口。务必先保留 SSH 端口，避免把自己锁在 VPS 外面。

### 端口放行表

| 端口 | 协议 | 用途 | 何时需要开放公网 |
|---:|---|---|---|
| 22 | TCP | SSH 管理 | 始终需要，按需限制来源 IP |
| 80 | TCP | Let's Encrypt HTTP-01 证书申请 | 填写代理连接域名并申请证书时需要；证书续期也需要 |
| 4433 | TCP | VLESS Reality Vision | 使用该直连节点时 |
| 4434 | TCP | VLESS Reality gRPC | 使用该直连节点时 |
| 8443 | UDP | Hysteria2 | 有代理域名并使用该节点时 |
| 8444 | UDP | TUIC | 有代理域名并使用该节点时 |
| 8445 | TCP | AnyTLS | 有代理域名并使用该节点时 |
| 8446 | TCP | Snell | 使用该直连节点时 |
| 8447 | TCP | Trojan TLS | 有代理域名并使用该节点时 |
| 8448 | TCP | Shadowsocks IPv6 | VPS 检测到 IPv6且使用该节点时 |

模式 1 若订阅通过 `node.example.com:18080` 直连发布，还需要放行 **18080/TCP**。模式 2/3 的订阅和 Argo 入口通过 Tunnel 转发，通常不需要把 18079、18080、18081、18082、18083 这些内部端口暴露到公网。

### Ubuntu 使用 UFW（如果系统已安装并启用）

先允许 SSH，再按实际使用的协议放行。以下是全协议示例：

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 4433/tcp
ufw allow 4434/tcp
ufw allow 8443/udp
ufw allow 8444/udp
ufw allow 8445/tcp
ufw allow 8446/tcp
ufw allow 8447/tcp
ufw allow 8448/tcp
ufw status verbose
```

如果使用模式 1 且通过直连域名发布订阅，再执行：

```bash
ufw allow 18080/tcp
```

如果 UFW 尚未启用，确认 SSH 放行后再启用：

```bash
ufw enable
```

不要在不清楚现有防火墙规则的情况下直接执行 `ufw reset`。如果使用 nftables、iptables 或服务商防火墙，请按同样的端口表配置，不要重复叠加不必要的规则。

**模式 2/3 的 Cloudflare Tunnel 需要 VPS 主动访问 Cloudflare 网络。** 一般不需要为 Tunnel 单独开放入站 443；不要把 Tunnel 内部端口误当作公网服务端口开放。

---

## 八、检查部署是否正常

### 1. 查看服务状态

Ubuntu/Debian：

```bash
systemctl status suoha-v2 --no-pager
systemctl status suoha-sub --no-pager
systemctl status suoha-argo-router --no-pager
systemctl status suoha-tunnel --no-pager
```

某些模式下并不会启用所有服务：模式 1 不需要 Argo Router 和 Tunnel；模式 2/3 才需要它们。显示某个不存在的可选服务，不代表核心 sing-box 一定故障。

也可以统一查看：

```bash
/usr/local/bin/suoha-v2 status
```

### 2. 检查 sing-box 配置

```bash
sing-box check -c /etc/suoha-v2/config.json
```

配置检查应成功退出，不应有 JSON 或配置字段错误。

### 3. 检查监听端口

```bash
ss -lntup
```

确认实际启用的端口处于监听状态。TCP 和 UDP 监听分别检查；某些协议只有填写代理域名后才会生成。

### 4. 查看订阅文件是否生成

```bash
ls -lah /etc/suoha-v2/subscription/
```

正常情况下可看到：

- `nodes.txt`：URI 节点列表；
- `sub.txt`：Base64 订阅；
- `clash.yaml`：Clash/Mihomo 配置；
- `surge.conf`：Surge 配置。

查看节点名称（不要把含有完整 UUID/密码的文件内容发到公开场合）：

```bash
grep -E '^vless://|^trojan://|^hysteria2://|^tuic://' /etc/suoha-v2/subscription/nodes.txt | sed -E 's#://[^@]*@#://[凭证隐藏]@#' | head
```

### 5. 查看日志

```bash
journalctl -u suoha-v2 -n 100 --no-pager
journalctl -u suoha-sub -n 80 --no-pager
journalctl -u suoha-argo-router -n 80 --no-pager
journalctl -u suoha-tunnel -n 100 --no-pager
```

脚本安装日志：

```bash
tail -n 100 /var/log/suoha-v2/install.log
```

### 6. Cloudflare Named Tunnel 检查（模式 3）

```bash
cloudflared tunnel list
systemctl status suoha-tunnel --no-pager
journalctl -u suoha-tunnel -n 100 --no-pager
```

确认 Tunnel 有连接器、服务处于运行状态，日志没有持续认证失败或连接失败。Cloudflare DNS 页面应能看到 `sub` 和 `argo` 子域名被路由到对应 Tunnel。

不要查看、复制或发送 `/root/.cloudflared/*.json` 的内容；它们是 Tunnel 凭证。

---

## 九、获取订阅并导入客户端

安装结束时脚本会打印订阅地址。建议优先使用 Clash/Mihomo YAML 订阅。

### 模式 1：直连

如果设置了代理连接域名，输出通常类似：

```text
https://node.example.com:18080/<订阅Token>/clash.yaml
```

也会提供 Base64、URI 列表和 Surge 地址。此模式下 18080/TCP 必须在系统防火墙和服务商安全组放行。

如果代理连接域名留空，脚本显示的订阅地址可能是 `127.0.0.1`，只能在 VPS 本机访问，不是可直接填入手机或路由器的公网订阅。

### 模式 2：Quick Tunnel

使用脚本输出的 `https://<随机名称>.trycloudflare.com/<订阅Token>/clash.yaml`。如果 Quick Tunnel 地址改变，运行：

```bash
/usr/local/bin/suoha-v2 refresh
/usr/local/bin/suoha-v2 status
```

然后复制新的订阅地址并在客户端更新。

### 模式 3：Named Tunnel

使用脚本输出的自有域名地址，例如：

```text
https://sub.example.com/<订阅Token>/clash.yaml
```

把该地址添加到 Clash、Mihomo、Nikki 或其他兼容客户端的远程配置/订阅管理中，执行更新。

### 导入后建议

1. 先单独测试一个 VLESS Reality 节点；
2. 再测试 Hysteria2/TUIC 等 UDP 协议（前提是已设置代理域名和证书）；
3. 最后测试 Argo WS 节点；
4. 若节点能导入但不能连接，检查客户端错误日志、服务端监听端口、VPS 安全组和 Cloudflare Tunnel，不要立即重装。

脚本会为 Argo 生成多组 Cloudflare Anycast 候选 IP。候选 IP 是否适合你的网络，需要在实际客户端网络环境测速；不能保证所有候选 IP 都可用或都比域名连接快。

---

## 十、节点名称前缀管理

安装时可以输入前缀，例如 `DMIT-`。部署后随时可修改，不需要重新安装节点。

```bash
# 设置前缀
/usr/local/bin/suoha-v2 prefix 'DMIT-'

# 改成其他前缀
/usr/local/bin/suoha-v2 prefix 'US-'

# 清除前缀
/usr/local/bin/suoha-v2 prefix ''
```

前缀仅改变客户端显示的节点名称，不改变协议、地址、端口、UUID、密码、证书、Tunnel 或 WebSocket 路径。执行后在客户端手动更新订阅。

---

## 十一、日常管理命令

```bash
# 查看状态和订阅地址
/usr/local/bin/suoha-v2 status

# 重新生成订阅文件
/usr/local/bin/suoha-v2 refresh

# 设置节点名称前缀
/usr/local/bin/suoha-v2 prefix 'DMIT-'

# 清除节点名称前缀
/usr/local/bin/suoha-v2 prefix ''

# 检查 sing-box 配置
sing-box check -c /etc/suoha-v2/config.json

# 查看核心服务日志
journalctl -u suoha-v2 -n 100 --no-pager

# 查看安装日志
tail -n 100 /var/log/suoha-v2/install.log
```

**不要为了修改节点前缀执行 `upgrade`。** 当前脚本的 `upgrade` 会停止服务并重新走配置安装流程，不是简单的脚本更新命令。不要在没有备份和明确升级计划时执行。

---

## 十二、备份和恢复

### 1. 首次部署成功后立即备份

配置目录含有全部节点凭证、订阅 Token、证书和 Tunnel 配置，必须妥善保管：

```bash
BACKUP="/root/suoha-v2-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$BACKUP"
cp -a /etc/suoha-v2 "$BACKUP/"
cp -a /var/log/suoha-v2 "$BACKUP/" 2>/dev/null || true
cp -a /usr/local/bin/suoha-v2 "$BACKUP/" 2>/dev/null || true
chmod -R go-rwx "$BACKUP"
echo "备份目录：$BACKUP"
```

如果使用 Named Tunnel，还应安全备份 `/root/.cloudflared/` 中需要的凭证文件。备份文件不要发给他人或上传到公开网盘。

### 2. 恢复时注意

恢复前先停止相关服务，并确认备份确实属于这台 VPS。不要把另一台 VPS 的配置目录直接覆盖到当前 VPS，尤其不要混用证书、IP、Tunnel JSON 和域名设置。

---

## 十三、常见问题排查

### 1. 证书申请失败

检查：

- 代理域名 A 记录是否指向当前 VPS；
- Cloudflare 代理是否为 DNS only；
- 公网 TCP 80 是否在服务商防火墙和 VPS 防火墙放行；
- TCP 80 是否被 Nginx/Apache/Caddy 等占用；
- 域名 AAAA 记录是否指向正确的 IPv6。

日志：

```bash
tail -n 150 /var/log/suoha-v2/install.log
```

不要随意删除 `/etc/suoha-v2/acme`、`/etc/suoha-v2/acme-config` 或 `/etc/suoha-v2/cert`。

### 2. sing-box 服务启动失败

```bash
sing-box check -c /etc/suoha-v2/config.json
journalctl -u suoha-v2 -n 150 --no-pager
ss -lntup
```

重点检查配置错误、端口冲突、证书文件是否存在，以及端口是否被其他程序占用。

### 3. Named Tunnel 无法启动

```bash
cloudflared tunnel list
systemctl status suoha-tunnel --no-pager
journalctl -u suoha-tunnel -n 150 --no-pager
ls -lah /root/.cloudflared/
```

常见原因：Cloudflare 授权未完成、Tunnel 凭证 JSON 不存在、Tunnel 名称与旧部署冲突、DNS 记录仍指向旧 Tunnel，或服务配置中的域名不匹配。不要把 JSON 凭证内容贴出来。

### 4. 订阅能打开，但节点连接超时

按顺序检查：

1. 客户端是否更新到了最新订阅；
2. VPS 上对应协议端口是否监听；
3. 服务商安全组和系统防火墙是否放行正确 TCP/UDP 端口；
4. 域名解析是否指向正确 VPS；
5. UDP 协议是否被当前网络限制；
6. Argo 节点是否能访问 Cloudflare Edge，Tunnel 和 Argo Router 是否正常。

### 5. 订阅地址返回 404

检查 URL 中的 Token 是否完整、域名是否正确、Tunnel 是否在线、订阅服务是否运行。订阅 Token 相当于访问凭证，不要公开分享。

---

## 十四、安全注意事项

- SSH 建议使用密钥登录；确认新密钥可用后，再考虑关闭密码登录。不要在尚未验证密钥前关闭密码登录。
- 保留 SSH 管理端口，防火墙变更前先允许 SSH。
- `credentials.env`、`settings.env`、订阅 Token、UUID、协议密码、Reality 私钥、证书私钥和 Cloudflare Tunnel JSON 都属于敏感信息。
- 不要把 `/etc/suoha-v2/credentials.env`、`/root/.cloudflared/*.json` 或完整订阅 URL 发到公开论坛、群聊或截图中。
- Cloudflare Tunnel 与代理直连域名是两类入口，不要把代理直连域名设置成橙云后期待任意 TCP/UDP 端口都能通过 Cloudflare。
- 定期更新系统；升级脚本或 sing-box 前先备份，并确认版本兼容性。
- 不要在一台 VPS 上同时运行多个监听相同端口的代理服务。

---

## 十五、全新部署完成检查清单

- [ ] VPS 使用受支持的 Ubuntu/Debian/Alpine 系统和 amd64/arm64 架构
- [ ] 已通过 root SSH 登录
- [ ] 已完成系统更新
- [ ] 域名 DNS 记录已按模式准备
- [ ] 代理直连域名（若使用）为 DNS only，且 TCP 80 可达
- [ ] 已上传 `suoha-v2.1.2-prefix.sh`
- [ ] `bash -n` 语法检查通过
- [ ] 已选择正确的模式并完成交互配置
- [ ] 已完成 Cloudflare 授权（模式 3）
- [ ] VPS 防火墙和服务商安全组已放行所需端口
- [ ] `sing-box check` 通过
- [ ] `suoha-v2` 服务运行正常
- [ ] 需要的订阅服务 / Argo Router / Tunnel 运行正常
- [ ] 已导入客户端并至少测试一个节点
- [ ] 已备份 `/etc/suoha-v2` 和相关凭证

**建议的首次部署顺序：** 准备系统 → 准备域名 → 上传脚本 → 语法检查 → 安装 → 放行端口 → 检查服务 → 导入订阅 → 测试节点 → 备份配置。
