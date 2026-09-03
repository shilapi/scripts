# scripts

Useful scripts, partly by AI

**Use at your own risk**

## fetch-cert

从 HTTP Basic Auth 保护的 URL 获取证书文件，并可按指定间隔自动更新。脚本不内置任何域名、远端路径、本地路径或账户信息；也不会重载任何服务或校验证书内容。

```bash
sudo ./fetch-cert.sh \
  --url 'https://example.invalid/cert/fullchain.cer' \
  --user 'slave' \
  --password 'your-password' \
  --output '/etc/ssl/example/fullchain.cer' \
  --interval 86400
```

参数说明：

- `--url`：远端证书的完整 URL。
- `--user`、`--password`：HTTP Basic Auth 账户和密码。
- `--output`：本机的目标文件完整路径。
- `--interval`：可选，更新间隔（秒）。省略时仅获取一次。

下载先写入目标文件同目录的临时文件，成功后再原子更新目标文件，避免写入半份内容。由于密码作为命令行参数可能会进入 Shell 历史记录或短暂显示在进程列表中，建议仅在受信任的环境运行，并限制脚本启动方式的访问权限。

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
