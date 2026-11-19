# Suoha V2.1.3｜GitHub 拉取、安装、管理与卸载

> 本教程只说明脚本本身的下载、安装、日常管理、升级和卸载命令，不包含 VPS 初始化、网络或防火墙配置。

## 1. 从 GitHub 下载脚本

请将新版脚本 `suoha-v2.1.3-prefix-tunnel.sh` 上传到自己的 GitHub 仓库后，再使用对应的 Raw 地址下载。示例：

```bash
curl -fL --retry 3 'https://raw.githubusercontent.com/你的用户名/你的仓库/你的分支/suoha-v2.1.3-prefix-tunnel.sh' -o /root/suoha-v2.1.3.sh
```

如果你将新版覆盖仓库原来的 `suoha.sh`，则把上面的 Raw 地址改成该文件对应的地址即可。

## 2. 检查并安装

```bash
chmod 700 /root/suoha-v2.1.3.sh
bash -n /root/suoha-v2.1.3.sh
bash /root/suoha-v2.1.3.sh install
```

安装过程中按提示选择模式、输入节点名称前缀等信息。

选择 **3) Cloudflare Named Tunnel** 时，会额外提示：

```text
Cloudflare Named Tunnel 名称 [默认 suoha-v2]：
```

- 输入自定义名称，例如 `suoha-v2-dmit-01`，则使用该名称。
- 直接回车，则使用默认名称 `suoha-v2`。
- 允许英文字母、数字和短横线，长度 1–64 位，不能以短横线开头或结尾。
- 名称会保存到 `/etc/suoha-v2/settings.env`，后续服务按保存的名称运行。
- 如果 Cloudflare 账户中已有同名 Tunnel，但本机没有对应凭证文件，脚本会停止并提示改用唯一名称，避免错误复用其他 VPS 的 Tunnel。

## 3. 常用管理命令

```bash
# 查看运行状态及订阅信息
suoha-v2 status

# 重新生成订阅文件
suoha-v2 refresh

# 设置节点名称前缀
suoha-v2 prefix 'DMIT-'

# 清空节点名称前缀
suoha-v2 prefix ''

# 检查 sing-box 配置
sing-box check -c /etc/suoha-v2/config.json
```

节点前缀只改变客户端显示名称，不改变节点连接参数。

## 4. 升级

先下载新版脚本，再执行：

```bash
chmod 700 /root/suoha-v2.1.3.sh
bash -n /root/suoha-v2.1.3.sh
bash /root/suoha-v2.1.3.sh upgrade
```

**注意：** `upgrade` 会备份现有配置、停止旧服务，然后重新进入安装配置流程；它不是只替换脚本文件。请按提示重新确认配置，Named Tunnel 应填写原来使用的名称，并确保本机仍保留对应凭证。

## 5. 卸载

```bash
suoha-v2 uninstall
```

按提示输入大写 `YES` 确认。脚本会备份 Suoha 配置和凭证，再删除 Suoha 服务及配置。为避免影响其他程序共用的组件，`cloudflared`、`sing-box` 二进制和系统依赖会保留。

## 6. 重要文件位置

| 内容 | 路径 |
|---|---|
| 管理命令 | `/usr/local/bin/suoha-v2` |
| 主配置 | `/etc/suoha-v2/config.json` |
| 安装设置 | `/etc/suoha-v2/settings.env` |
| 节点凭证 | `/etc/suoha-v2/credentials.env` |
| 订阅文件 | `/etc/suoha-v2/subscription/` |
| 安装日志 | `/var/log/suoha-v2/install.log` |
| Cloudflare Tunnel 凭证 | `/root/.cloudflared/` |

请勿公开 `credentials.env`、订阅 Token、UUID、密码、Reality 私钥或 Cloudflare Tunnel JSON 凭证。
