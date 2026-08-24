#!/bin/sh
set -eu

PROGRAM='cf-ddns'
INSTALL_PATH='/usr/local/bin/cf-ddns'
CONFIG_PATH='/etc/cf-ddns.conf'
RECORDS_PATH='/etc/cf-ddns.records'
CRONTAB_PATH='/etc/crontabs/root'
LOG_PATH='/var/log/cf-ddns.log'
CRON_MARKER='# cf-ddns-managed'
API_BASE='https://api.cloudflare.com/client/v4'
IP_URL='https://cloudflare.com/cdn-cgi/trace'

say() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    say "ERROR: $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die '请使用 root 运行'
}

valid_dns_name() {
    printf '%s\n' "$1" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
}

validate_credentials() {
    [ -n "${CF_API_TOKEN:-}" ] || die 'Cloudflare API Token 为空'
    printf '%s\n' "$CF_API_TOKEN" | grep -Eq '^[A-Za-z0-9_-]+$' \
        || die 'Cloudflare API Token 格式异常'
    valid_dns_name "$CF_ZONE" || die "主域名格式无效: $CF_ZONE"
    case "$CF_ZONE" in
        *.*) ;;
        *) die '主域名应类似 example.com' ;;
    esac
}

load_config() {
    [ -r "$CONFIG_PATH" ] || die "尚未配置，请使用: $0 -d example.com -key TOKEN"
    # 文件仅 root 可读，且写入前已校验为安全字符。
    # shellcheck disable=SC1090
    . "$CONFIG_PATH"
    validate_credentials
}

save_config() {
    domain_arg=$1
    token_arg=$2
    old_domain=''
    old_token=''

    if [ -r "$CONFIG_PATH" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_PATH"
        old_domain=${CF_ZONE:-}
        old_token=${CF_API_TOKEN:-}
    fi

    [ -n "$domain_arg" ] || domain_arg=$old_domain
    [ -n "$token_arg" ] || token_arg=$old_token
    CF_ZONE=$(printf '%s' "$domain_arg" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    CF_API_TOKEN=$token_arg
    validate_credentials

    if [ -n "$old_domain" ] && [ "$old_domain" != "$CF_ZONE" ] \
        && [ -s "$RECORDS_PATH" ]; then
        die "已有 DDNS 记录，不能直接把主域名从 $old_domain 改为 $CF_ZONE；请先删除现有 DDNS"
    fi

    umask 077
    {
        printf 'CF_ZONE=%s\n' "$CF_ZONE"
        printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN"
    } > "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

record_name() {
    subdomain=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    case "$subdomain" in
        ''|'@') record=$CF_ZONE ;;
        "$CF_ZONE") record=$CF_ZONE ;;
        *."$CF_ZONE") record=$subdomain ;;
        *) record=$subdomain.$CF_ZONE ;;
    esac
    valid_dns_name "$record" || die "子域名格式无效: $1"
    case "$record" in
        "$CF_ZONE"|*."$CF_ZONE") printf '%s\n' "$record" ;;
        *) die "$record 不属于主域名 $CF_ZONE" ;;
    esac
}

api() {
    method=$1
    url=$2
    data=${3:-}

    if [ -n "$data" ]; then
        curl -sS --connect-timeout 10 --max-time 30 --retry 2 \
            -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H 'Content-Type: application/json' \
            --data "$data"
    else
        curl -sS --connect-timeout 10 --max-time 30 --retry 2 \
            -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H 'Content-Type: application/json'
    fi
}

check_api_result() {
    response=$1
    if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        message=$(printf '%s' "$response" | jq -r \
            '[.errors[]? | ((.code // "?") | tostring) + ": " + (.message // "unknown error")] | join("; ")' \
            2>/dev/null || true)
        [ -n "$message" ] || message='Cloudflare 返回了无效响应'
        die "$message"
    fi
}

zone_id() {
    zone_json=$(api GET "$API_BASE/zones?name=$CF_ZONE&status=active&per_page=2") \
        || die '查询 Cloudflare Zone 失败'
    check_api_result "$zone_json"
    zone_count=$(printf '%s' "$zone_json" | jq '.result | length')
    [ "$zone_count" -eq 1 ] \
        || die "找不到唯一的活动 Zone: $CF_ZONE（找到 $zone_count 个）"
    printf '%s' "$zone_json" | jq -r '.result[0].id'
}

public_ip() {
    family=$1
    trace=$(curl "-$family" -fsS --connect-timeout 10 --max-time 20 --retry 2 "$IP_URL") \
        || return 1
    ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n 1)
    [ -n "$ip" ] || ip=$(printf '%s' "$trace" | tr -d '[:space:]')

    if [ "$family" = 4 ]; then
        printf '%s\n' "$ip" | awk -F. '
            NF != 4 { exit 1 }
            {
                for (i = 1; i <= 4; i++) {
                    if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
                }
            }
        ' || return 1
    else
        [ "${#ip}" -le 45 ] || return 1
        printf '%s\n' "$ip" | grep -Eq '^[0-9A-Fa-f:]+$' || return 1
        printf '%s\n' "$ip" | grep -q ':' || return 1
    fi
    printf '%s\n' "$ip"
}

sync_dns_record() {
    zone=$1
    record=$2
    dns_type=$3
    ip=$4
    dns_json=$(api GET "$API_BASE/zones/$zone/dns_records?type=$dns_type&name=$record&per_page=2") \
        || die "查询 $dns_type 记录失败"
    check_api_result "$dns_json"
    dns_count=$(printf '%s' "$dns_json" | jq '.result | length')
    payload=$(jq -nc --arg type "$dns_type" --arg name "$record" \
        --arg content "$ip" \
        '{type:$type, name:$name, content:$content, ttl:1, proxied:false}')

    case "$dns_count" in
        0)
            result=$(api POST "$API_BASE/zones/$zone/dns_records" "$payload") \
                || die "创建 $dns_type 记录失败"
            check_api_result "$result"
            say "已创建 $dns_type $record -> $ip"
            ;;
        1)
            dns_id=$(printf '%s' "$dns_json" | jq -r '.result[0].id')
            old_ip=$(printf '%s' "$dns_json" | jq -r '.result[0].content')
            old_proxied=$(printf '%s' "$dns_json" | jq -r '.result[0].proxied')
            if [ "$old_ip" = "$ip" ] && [ "$old_proxied" = false ]; then
                say "无需更新 $dns_type $record，当前仍为 $ip"
                return 0
            fi
            result=$(api PATCH "$API_BASE/zones/$zone/dns_records/$dns_id" "$payload") \
                || die "更新 $dns_type 记录失败"
            check_api_result "$result"
            say "已更新 $dns_type $record: $old_ip -> $ip"
            ;;
        *) die "$record 存在多个 $dns_type 记录，请先删除重复项" ;;
    esac
}

sync_records() {
    load_config
    [ "$#" -gt 0 ] || return 0
    ipv4=''
    ipv6=''
    failed=0

    if ! ipv4=$(public_ip 4); then
        say 'ERROR: 无法通过 IPv4 查询公网地址' >&2
        failed=1
    fi
    if ! ipv6=$(public_ip 6); then
        say 'ERROR: 无法通过 IPv6 查询公网地址；请确认服务器具有公网 IPv6' >&2
        failed=1
    fi
    [ -n "$ipv4$ipv6" ] || die 'IPv4 和 IPv6 均不可用'
    zone=$(zone_id)

    for record in "$@"; do
        [ -z "$ipv4" ] || sync_dns_record "$zone" "$record" A "$ipv4"
        [ -z "$ipv6" ] || sync_dns_record "$zone" "$record" AAAA "$ipv6"
    done
    [ "$failed" -eq 0 ]
}

sync_all() {
    need_root
    command -v curl >/dev/null 2>&1 || die '缺少 curl'
    command -v jq >/dev/null 2>&1 || die '缺少 jq'
    load_config
    [ -s "$RECORDS_PATH" ] || { say '没有已配置的 DDNS'; return 0; }

    # 记录名已在添加时严格校验，不含空格。
    # shellcheck disable=SC2046
    sync_records $(sed '/^[[:space:]]*$/d' "$RECORDS_PATH")
}

install_dependencies() {
    command -v apk >/dev/null 2>&1 || die '此脚本面向 Alpine Linux（未找到 apk）'
    apk add --no-cache curl jq ca-certificates
}

install_program() {
    install_dependencies
    mkdir -p /usr/local/bin /etc/crontabs
    temp_path="$INSTALL_PATH.new.$$"
    cp "$0" "$temp_path"
    chmod 700 "$temp_path"
    mv "$temp_path" "$INSTALL_PATH"
    touch "$RECORDS_PATH" "$CRONTAB_PATH"
    chmod 600 "$RECORDS_PATH" "$CRONTAB_PATH"

    sed -i "\|$CRON_MARKER$|d" "$CRONTAB_PATH"
    printf '17 2 * * * %s --sync-all >>%s 2>&1 %s\n' \
        "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >> "$CRONTAB_PATH"

    if command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond restart >/dev/null 2>&1 \
            || rc-service crond start >/dev/null 2>&1 \
            || true
    elif ! pidof crond >/dev/null 2>&1; then
        crond
    fi
}

service_status() {
    if [ -x "$INSTALL_PATH" ] \
        && grep -Fq "$CRON_MARKER" "$CRONTAB_PATH" 2>/dev/null; then
        if pidof crond >/dev/null 2>&1; then
            printf '已安装 / 运行中'
        else
            printf '已安装 / crond 未运行'
        fi
    else
        printf '未安装'
    fi
}

record_count() {
    if [ -s "$RECORDS_PATH" ]; then
        sed '/^[[:space:]]*$/d' "$RECORDS_PATH" | wc -l | tr -d '[:space:]'
    else
        printf '0'
    fi
}

show_records() {
    if [ -s "$RECORDS_PATH" ]; then
        awk 'NF { printf "  %d) %s\n", ++n, $0 }' "$RECORDS_PATH"
    else
        printf '  （无）\n'
    fi
}

add_ddns() {
    printf '请输入子域名（如 home、nas.home；根域名填 @）: '
    IFS= read -r subdomain
    [ -n "$subdomain" ] || die '子域名不能为空'
    record=$(record_name "$subdomain")

    install_program
    if grep -Fxq "$record" "$RECORDS_PATH"; then
        say "$record 已存在，立即重新同步"
    else
        printf '%s\n' "$record" >> "$RECORDS_PATH"
        say "已添加 DDNS: $record"
    fi

    if sync_records "$record"; then
        say 'IPv4 与 IPv6 同步完成'
    else
        say '部分地址同步失败，定时任务稍后会重试' >&2
    fi
}

delete_remote_type() {
    zone=$1
    record=$2
    dns_type=$3
    dns_json=$(api GET "$API_BASE/zones/$zone/dns_records?type=$dns_type&name=$record&per_page=100") \
        || die "查询 $dns_type 记录失败"
    check_api_result "$dns_json"
    ids=$(printf '%s' "$dns_json" | jq -r '.result[].id')
    [ -n "$ids" ] || { say "Cloudflare 中没有 $dns_type $record"; return 0; }

    for dns_id in $ids; do
        result=$(api DELETE "$API_BASE/zones/$zone/dns_records/$dns_id") \
            || die "删除 $dns_type 记录失败"
        check_api_result "$result"
    done
    say "已删除 Cloudflare $dns_type 记录: $record"
}

delete_ddns() {
    load_config
    [ -s "$RECORDS_PATH" ] || { say '没有可删除的 DDNS'; return 0; }
    printf '\n当前 DDNS：\n'
    show_records
    printf '请选择要删除的编号: '
    IFS= read -r selection
    case "$selection" in
        ''|*[!0-9]*) die '编号无效' ;;
    esac
    record=$(sed -n "${selection}p" "$RECORDS_PATH")
    [ -n "$record" ] || die '编号不存在'
    printf '将删除本地任务以及 Cloudflare 的 A/AAAA：%s，确认？[y/N]: ' "$record"
    IFS= read -r confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) say '已取消'; return 0 ;;
    esac

    zone=$(zone_id)
    delete_remote_type "$zone" "$record" A
    delete_remote_type "$zone" "$record" AAAA
    temp_records="$RECORDS_PATH.new.$$"
    grep -Fxv "$record" "$RECORDS_PATH" > "$temp_records" || true
    chmod 600 "$temp_records"
    mv "$temp_records" "$RECORDS_PATH"
    say "已删除 DDNS: $record"
}

uninstall_service() {
    printf '将卸载本机 DDNS 服务和配置；Cloudflare 记录会保留。确认？[y/N]: '
    IFS= read -r confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) say '已取消'; return 0 ;;
    esac

    if [ -f "$CRONTAB_PATH" ]; then
        sed -i "\|$CRON_MARKER$|d" "$CRONTAB_PATH"
    fi
    rm -f "$CONFIG_PATH" "$RECORDS_PATH" "$LOG_PATH" "$INSTALL_PATH"
    say '本机 DDNS 服务已删除；未删除 Cloudflare 上现有的 DNS 记录'
}

show_panel() {
    load_config
    while :; do
        printf '\n'
        printf '+--------------------------------------------------+\n'
        printf '| Cloudflare DDNS 管理面板                         |\n'
        printf '+--------------------------------------------------+\n'
        printf '| 主域名: %-39s |\n' "$CF_ZONE"
        printf '| 服务状态: %-37s |\n' "$(service_status)"
        printf '| DDNS 数量: %-37s |\n' "$(record_count)"
        printf '+--------------------------------------------------+\n'
        printf '  1) 添加 DDNS（自动创建/更新 A + AAAA）\n'
        printf '  2) 删除 DDNS（同时删除 Cloudflare A + AAAA）\n'
        printf '  3) 删除本机 DDNS 服务（保留 Cloudflare 记录）\n'
        printf '  4) 查看 DDNS 列表\n'
        printf '  0) 退出\n'
        printf '请选择 [0-4]: '
        IFS= read -r choice

        case "$choice" in
            1) add_ddns ;;
            2) delete_ddns ;;
            3) uninstall_service; return 0 ;;
            4) printf '\n'; show_records ;;
            0) return 0 ;;
            *) say '无效选项' ;;
        esac
    done
}

usage() {
    cat <<EOF
用法：
  $0 -d lapiw.icu -key 'Cloudflare_API_Token'
  $0                         # 已配置后直接打开管理面板

Token 需要 Zone:Read 和 DNS:Edit 权限。
EOF
}

if [ "${1:-}" = '--sync-all' ]; then
    sync_all
    exit $?
fi

need_root
domain_arg=''
token_arg=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--domain)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            domain_arg=$2
            shift 2
            ;;
        -key|--key)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            token_arg=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "未知参数: $1" ;;
    esac
done

if [ -n "$domain_arg$token_arg" ]; then
    save_config "$domain_arg" "$token_arg"
elif [ ! -r "$CONFIG_PATH" ]; then
    usage
    exit 2
fi

show_panel
