# scripts

Useful scripts, partly by AI

**Use at your own risk**

## fetch-cert

从 HTTP Basic Auth 保护的 URL 获取证书文件，并由脚本自行安装和管理 cron 定时任务。脚本不内置任何证书域名、远端路径、本地路径或账户信息；它们只在首次配置时通过参数传入。脚本不会重载任何服务或校验证书内容。

```bash
sudo ./fetch-cert.sh \
  --url '远端证书完整 URL' \
  --user 'HTTP Basic Auth 用户名' \
  --password 'HTTP Basic Auth 密码' \
  --output '本机证书完整路径' \
  --interval '3d'
```

参数说明：

- `--url`：远端证书的完整 URL。
- `--user`、`--password`：HTTP Basic Auth 账户和密码。
- `--output`：本机的目标文件完整路径。
- `--interval`：可选，更新周期，格式为正整数加 `d`。例如 `3d` 表示每 3 天、`5d` 表示每 5 天；默认 `7d`。

首次配置会立即获取一次证书，随后安装 cron 任务。脚本会复制到 `/usr/local/bin/fetch-cert`，配置保存在仅 root 可读的 `/etc/fetch-cert.conf`，cron 此后从这份配置读取账户、密码、远端 URL 和目标路径。下载先写入目标文件同目录的临时文件，成功后再原子更新目标文件，避免写入半份内容。

支持 Alpine Linux 与 Debian/Ubuntu；在 Debian/Ubuntu 中任务文件为 `/etc/cron.d/fetch-cert`，在 Alpine 中写入 root 的 `/etc/crontabs/root`。cron 每小时第 17 分钟运行一次检查，到达设定周期后才实际下载，因此时间误差最多约 1 小时。若系统未安装 curl 或 cron，首次配置时会自动安装。

修改证书地址、账户、密码、本地路径或周期，只需再次使用完整参数运行脚本；旧 cron 任务会被更新。改为每 5 天更新：

```bash
sudo ./fetch-cert.sh \
  --url '远端证书完整 URL' \
  --user 'HTTP Basic Auth 用户名' \
  --password 'HTTP Basic Auth 密码' \
  --output '本机证书完整路径' \
  --interval '5d'
```

首次配置会立即下载。之后 `sudo /usr/local/bin/fetch-cert --sync` 只会在周期到期时下载。删除脚本管理的 cron 任务、配置、日志和程序副本可使用 `sudo /usr/local/bin/fetch-cert --uninstall`。由于密码首次作为命令行参数传入，可能会进入 Shell 历史记录或短暂显示在进程列表中，建议仅在受信任的环境运行，并限制脚本启动方式的访问权限。

## network

### cf-ddns

Cloudflare DDNS script for Alpine Linux and Debian/Ubuntu. It can maintain IPv4
(A) and IPv6 (AAAA) records independently.

#### Usage

```bash
cf-ddns.sh -d example.com -key 'CLOUDFLARE_KEY'
```

Run it as `root`. The interactive menu lets you add an IPv4-only, IPv6-only,
or dual-stack record. Configuration is saved to `/etc/cf-ddns.conf` (mode
`600`), and the managed record list is `/etc/cf-ddns.records`.
