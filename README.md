# scripts

Useful scripts, partly by AI

**Use at your own risk**

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
