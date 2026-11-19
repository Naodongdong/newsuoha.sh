# Suoha V2.1.2：GitHub 拉取、安装、管理与卸载

本说明只介绍脚本本身的下载、安装、日常管理、更新和卸载，不包含 VPS 选购、系统初始化、网络或防火墙配置。

以下命令均在 VPS 的 SSH 终端中以 `root` 身份执行。

## 1. 从 GitHub 下载脚本

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Naodongdong/newsuoha.sh/pro/suoha.sh -o /root/suoha-v2.1.2-prefix.sh
```

下载后检查文件是否存在：

```bash
ls -lh /root/suoha-v2.1.2-prefix.sh
```

## 2. 检查脚本并安装

先赋予执行权限并检查 Shell 语法：

```bash
chmod 700 /root/suoha-v2.1.2-prefix.sh
bash -n /root/suoha-v2.1.2-prefix.sh
```

如果语法检查没有任何输出，执行全新安装：

```bash
bash /root/suoha-v2.1.2-prefix.sh install
```

随后按照脚本交互提示选择部署模式、填写所需信息并完成安装。安装完成后，脚本会安装管理命令：

```bash
/usr/local/bin/suoha-v2
```

以后日常管理不需要再次运行下载的 `.sh` 文件。

## 3. 日常管理命令

查看运行状态和部署信息：

```bash
suoha-v2 status
```

刷新订阅和节点列表：

```bash
suoha-v2 refresh
```

设置节点名称前缀，例如统一加上 `DMIT-`：

```bash
suoha-v2 prefix 'DMIT-'
```

清除节点名称前缀：

```bash
suoha-v2 prefix ''
```

前缀只修改客户端显示的节点名称，不会修改节点协议、地址、端口或连接凭证。

检查 sing-box 配置是否正确：

```bash
sing-box check -c /etc/suoha-v2/config.json
```

## 4. 更新脚本

先重新从 GitHub 下载新版脚本（会覆盖本地下载文件）：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/Naodongdong/newsuoha.sh/pro/suoha.sh -o /root/suoha-v2.1.2-prefix.sh
chmod 700 /root/suoha-v2.1.2-prefix.sh
bash -n /root/suoha-v2.1.2-prefix.sh
```

确认语法检查无报错后执行：

```bash
bash /root/suoha-v2.1.2-prefix.sh upgrade
```

**注意：** `upgrade` 会先备份现有配置，再停止旧服务并重新执行安装流程；按提示重新确认配置。它不是单纯替换一个脚本文件，也不是只更新节点前缀。更新前请确认你下载到的是预期版本。

## 5. 完全卸载

执行：

```bash
suoha-v2 uninstall
```

程序会要求输入 `YES` 二次确认。确认后会停止并移除 Suoha V2 服务、配置和日志。

卸载时会自动把配置备份到类似下面的目录：

```text
/root/suoha-v2-backup-年月日-时分秒
```

卸载会保留 `sing-box`、`cloudflared` 二进制及系统依赖，避免误删其他程序可能共用的组件。Cloudflare 账户中的 Tunnel 不会因为本地卸载而自动删除；如确实要删除，请先确认该 Tunnel 没有被其他服务使用，再到 Cloudflare 控制台单独处理。

## 6. 常用命令速查

| 用途 | 命令 |
|---|---|
| 全新安装 | `bash /root/suoha-v2.1.2-prefix.sh install` |
| 查看状态 | `suoha-v2 status` |
| 刷新订阅 | `suoha-v2 refresh` |
| 设置前缀 | `suoha-v2 prefix 'DMIT-'` |
| 清空前缀 | `suoha-v2 prefix ''` |
| 更新安装 | `bash /root/suoha-v2.1.2-prefix.sh upgrade` |
| 检查配置 | `sing-box check -c /etc/suoha-v2/config.json` |
| 卸载 | `suoha-v2 uninstall` |

