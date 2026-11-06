#!/usr/bin/env bash
# IPv4 TCP/UDP port forwarding with daily DNS refresh.
# Forwarding targets and ports are collected interactively and stored only locally.

set -Eeuo pipefail

PROGRAM='port-forward'
INSTALL_PATH='/usr/local/sbin/port-forward'
CONFIG_DIR='/etc/port-forward'
RULES_PATH="$CONFIG_DIR/rules.tsv"
STATE_PATH="$CONFIG_DIR/enabled"
SYSCTL_PATH='/etc/sysctl.d/99-port-forward.conf'
LOG_PATH='/var/log/port-forward.log'
CRON_MARKER='# port-forward-managed'
SOURCE_URL='https://raw.githubusercontent.com/shilapi/scripts/main/network/port-forward.sh'
PLATFORM=''
CRONTAB_PATH=''
INPUT_FD=0

DNAT_CHAIN='PFWD_DNAT'
SNAT_CHAIN='PFWD_SNAT'
FILTER_CHAIN='PFWD_FILTER'

say() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
}

die() {
    say "错误：$*" >&2
    exit 1
}

need_root() {
    [[ $(id -u) -eq 0 ]] || die '请使用 root 或 sudo 运行'
}

detect_platform() {
    if command -v apk >/dev/null 2>&1; then
        PLATFORM='alpine'
        CRONTAB_PATH='/etc/crontabs/root'
    elif command -v apt-get >/dev/null 2>&1; then
        PLATFORM='debian'
        CRONTAB_PATH='/etc/cron.d/port-forward'
    else
        die '仅支持 Alpine Linux（apk）和 Debian/Ubuntu（apt-get）'
    fi
}

open_input() {
    if [[ -r /dev/tty ]]; then
        exec 3</dev/tty
        INPUT_FD=3
    fi
}

prompt() {
    local message=$1 variable=$2 input_value
    printf '%s' "$message" >/dev/tty 2>/dev/null || printf '%s' "$message"
    IFS= read -r -u "$INPUT_FD" input_value || die '无法读取输入'
    printf -v "$variable" '%s' "$input_value"
}

valid_ipv4() {
    awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    ' <<<"$1"
}

valid_domain() {
    local value=${1,,}
    [[ ${#value} -le 253 && $value == *.* ]] || return 1
    [[ $value =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_name() {
    [[ $1 =~ ^[A-Za-z0-9_.-]{1,40}$ ]]
}

parse_port_spec() {
    local spec=${1//:/-} start end
    if [[ $spec =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        start=$((10#${BASH_REMATCH[1]}))
        end=$((10#${BASH_REMATCH[2]}))
    elif [[ $spec =~ ^[0-9]{1,5}$ ]]; then
        start=$((10#$spec))
        end=$start
    else
        return 1
    fi
    ((start >= 1 && end <= 65535 && start <= end)) || return 1
    PORT_START=$start
    PORT_END=$end
}

port_match() {
    if [[ $1 == "$2" ]]; then
        printf '%s' "$1"
    else
        printf '%s:%s' "$1" "$2"
    fi
}

port_target() {
    if [[ $1 == "$2" ]]; then
        printf '%s' "$1"
    else
        printf '%s-%s' "$1" "$2"
    fi
}

resolve_target() {
    local target=${1,,} ip
    if valid_ipv4 "$target"; then
        printf '%s\n' "$target"
        return 0
    fi
    valid_domain "$target" || return 1
    ip=$(getent ahostsv4 "$target" 2>/dev/null \
        | awk '$1 ~ /^[0-9.]+$/ { print $1 }' \
        | sort -Vu | head -n 1)
    [[ -n $ip ]] && valid_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

ensure_storage() {
    mkdir -p "$CONFIG_DIR"
    touch "$RULES_PATH"
    [[ -f $STATE_PATH ]] || printf '0\n' >"$STATE_PATH"
    chmod 700 "$CONFIG_DIR"
    chmod 600 "$RULES_PATH" "$STATE_PATH"
}

is_enabled() {
    [[ -r $STATE_PATH ]] && [[ $(<"$STATE_PATH") == 1 ]]
}

install_dependencies() {
    case "$PLATFORM" in
        alpine)
            apk add --no-cache bash iptables musl-utils curl ca-certificates
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends bash iptables cron curl ca-certificates
            ;;
    esac
}

install_program() {
    local source_path temp_path
    mkdir -p "$(dirname "$INSTALL_PATH")"
    temp_path="$INSTALL_PATH.new.$$"
    source_path=${BASH_SOURCE[0]:-}

    if [[ -n $source_path && -f $source_path && $source_path != /dev/fd/* ]]; then
        install -m 700 "$source_path" "$temp_path"
    else
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
            "$SOURCE_URL" -o "$temp_path" \
            || die "无法从 $SOURCE_URL 安装脚本"
        chmod 700 "$temp_path"
    fi
    mv -f "$temp_path" "$INSTALL_PATH"
}

install_cron() {
    local temp_cron
    touch "$LOG_PATH"
    chmod 600 "$LOG_PATH"
    if [[ $PLATFORM == alpine ]]; then
        mkdir -p /etc/crontabs
        touch "$CRONTAB_PATH"
        chmod 600 "$CRONTAB_PATH"
        sed -i "\|$CRON_MARKER$|d" "$CRONTAB_PATH"
        printf '@reboot %s --sync >>%s 2>&1 %s\n' \
            "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >>"$CRONTAB_PATH"
        printf '17 4 * * * %s --sync >>%s 2>&1 %s\n' \
            "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >>"$CRONTAB_PATH"
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond restart >/dev/null 2>&1 \
            || rc-service crond start >/dev/null 2>&1 || true
    else
        mkdir -p /etc/cron.d
        temp_cron="$CRONTAB_PATH.new.$$"
        {
            printf '%s\n' 'SHELL=/bin/bash'
            printf '@reboot root %s --sync >>%s 2>&1 %s\n' \
                "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER"
            printf '17 4 * * * root %s --sync >>%s 2>&1 %s\n' \
                "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER"
        } >"$temp_cron"
        chmod 644 "$temp_cron"
        mv -f "$temp_cron" "$CRONTAB_PATH"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now cron >/dev/null 2>&1 || true
        else
            service cron restart >/dev/null 2>&1 || true
        fi
    fi
}

install_service() {
    detect_platform
    install_dependencies
    ensure_storage
    install_program
    install_cron
}

delete_jump() {
    local table=$1 parent=$2 child=$3
    while iptables -w 5 -t "$table" -C "$parent" -j "$child" >/dev/null 2>&1; do
        iptables -w 5 -t "$table" -D "$parent" -j "$child"
    done
}

remove_rules() {
    delete_jump nat PREROUTING "$DNAT_CHAIN"
    delete_jump nat POSTROUTING "$SNAT_CHAIN"
    delete_jump filter FORWARD "$FILTER_CHAIN"
    iptables -w 5 -t nat -F "$DNAT_CHAIN" >/dev/null 2>&1 || true
    iptables -w 5 -t nat -X "$DNAT_CHAIN" >/dev/null 2>&1 || true
    iptables -w 5 -t nat -F "$SNAT_CHAIN" >/dev/null 2>&1 || true
    iptables -w 5 -t nat -X "$SNAT_CHAIN" >/dev/null 2>&1 || true
    iptables -w 5 -t filter -F "$FILTER_CHAIN" >/dev/null 2>&1 || true
    iptables -w 5 -t filter -X "$FILTER_CHAIN" >/dev/null 2>&1 || true
}

create_or_flush_chain() {
    local table=$1 chain=$2
    iptables -w 5 -t "$table" -N "$chain" >/dev/null 2>&1 || true
    iptables -w 5 -t "$table" -F "$chain"
}

apply_one_rule() {
    local protocol=$1 listen_start=$2 listen_end=$3 ip=$4 target_start=$5 target_end=$6
    local listen_spec target_spec
    listen_spec=$(port_match "$listen_start" "$listen_end")
    target_spec=$(port_target "$target_start" "$target_end")

    iptables -w 5 -t nat -A "$DNAT_CHAIN" -p "$protocol" \
        --dport "$listen_spec" -j DNAT --to-destination "$ip:$target_spec"
    iptables -w 5 -t nat -A "$SNAT_CHAIN" -p "$protocol" -d "$ip" \
        --dport "$(port_match "$target_start" "$target_end")" -j MASQUERADE
    iptables -w 5 -t filter -A "$FILTER_CHAIN" -p "$protocol" -d "$ip" \
        --dport "$(port_match "$target_start" "$target_end")" \
        -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    iptables -w 5 -t filter -A "$FILTER_CHAIN" -p "$protocol" -s "$ip" \
        --sport "$(port_match "$target_start" "$target_end")" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

validate_rule_fields() {
    local id=$1 name=$2 protocol=$3 listen_start=$4 listen_end=$5
    local target=$6 target_start=$7 target_end=$8 ip=$9
    [[ $id =~ ^[0-9]+$ ]] || return 1
    valid_name "$name" || return 1
    [[ $protocol == tcp || $protocol == udp || $protocol == both ]] || return 1
    parse_port_spec "$listen_start-$listen_end" || return 1
    parse_port_spec "$target_start-$target_end" || return 1
    ((listen_end - listen_start == target_end - target_start)) || return 1
    valid_ipv4 "$target" || valid_domain "$target" || return 1
    valid_ipv4 "$ip" || return 1
}

apply_rules() {
    local id name protocol listen_start listen_end target target_start target_end ip proto
    create_or_flush_chain nat "$DNAT_CHAIN"
    create_or_flush_chain nat "$SNAT_CHAIN"
    create_or_flush_chain filter "$FILTER_CHAIN"

    while IFS=$'\t' read -r id name protocol listen_start listen_end target target_start target_end ip; do
        [[ -n $id ]] || continue
        validate_rule_fields "$id" "$name" "$protocol" "$listen_start" "$listen_end" \
            "$target" "$target_start" "$target_end" "$ip" \
            || die "配置文件中存在无效规则（ID: $id）"
        if [[ $protocol == both ]]; then
            for proto in tcp udp; do
                apply_one_rule "$proto" "$listen_start" "$listen_end" "$ip" "$target_start" "$target_end"
            done
        else
            apply_one_rule "$protocol" "$listen_start" "$listen_end" "$ip" "$target_start" "$target_end"
        fi
    done <"$RULES_PATH"

    iptables -w 5 -t nat -C PREROUTING -j "$DNAT_CHAIN" >/dev/null 2>&1 \
        || iptables -w 5 -t nat -I PREROUTING 1 -j "$DNAT_CHAIN"
    iptables -w 5 -t nat -C POSTROUTING -j "$SNAT_CHAIN" >/dev/null 2>&1 \
        || iptables -w 5 -t nat -I POSTROUTING 1 -j "$SNAT_CHAIN"
    iptables -w 5 -t filter -C FORWARD -j "$FILTER_CHAIN" >/dev/null 2>&1 \
        || iptables -w 5 -t filter -I FORWARD 1 -j "$FILTER_CHAIN"
}

refresh_targets() {
    local temp_path id name protocol listen_start listen_end target target_start target_end old_ip new_ip failed=0
    temp_path="$RULES_PATH.new.$$"
    : >"$temp_path"
    chmod 600 "$temp_path"
    while IFS=$'\t' read -r id name protocol listen_start listen_end target target_start target_end old_ip; do
        [[ -n $id ]] || continue
        if new_ip=$(resolve_target "$target"); then
            if [[ $new_ip != "$old_ip" ]]; then
                say "$name 的对端地址已更新：$old_ip -> $new_ip"
            fi
        elif valid_ipv4 "$old_ip"; then
            new_ip=$old_ip
            say "警告：无法解析 $target，暂时保留 $old_ip" >&2
            failed=1
        else
            rm -f "$temp_path"
            die "无法解析对端地址：$target"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "$protocol" "$listen_start" "$listen_end" \
            "$target" "$target_start" "$target_end" "$new_ip" >>"$temp_path"
    done <"$RULES_PATH"
    mv -f "$temp_path" "$RULES_PATH"
    return "$failed"
}

sync_rules() {
    need_root
    ensure_storage
    refresh_targets || true
    if is_enabled; then
        printf 'net.ipv4.ip_forward=1\n' >"$SYSCTL_PATH"
        sysctl -q -w net.ipv4.ip_forward=1
        apply_rules
        say '端口转发规则已同步'
    else
        remove_rules
        say '端口转发当前为关闭状态，仅更新了域名解析结果'
    fi
}

enable_forwarding() {
    printf '1\n' >"$STATE_PATH"
    sync_rules
    say '端口转发已打开'
}

disable_forwarding() {
    printf '0\n' >"$STATE_PATH"
    remove_rules
    rm -f "$SYSCTL_PATH"
    say '端口转发已关闭；未更改系统当前的 ip_forward 值，也未删除配置'
}

choose_protocol() {
    local choice
    prompt '协议 [1=TCP，2=UDP，3=TCP+UDP]: ' choice
    case "$choice" in
        1) RULE_PROTOCOL='tcp' ;;
        2) RULE_PROTOCOL='udp' ;;
        3) RULE_PROTOCOL='both' ;;
        *) die '协议选项无效' ;;
    esac
}

collect_rule() {
    local default_name=${1:-} default_protocol=${2:-} default_listen_start=${3:-}
    local default_listen_end=${4:-} default_target=${5:-} default_target_start=${6:-}
    local default_target_end=${7:-} value listen_spec target_spec

    prompt "名称（字母、数字、点、下划线或短横线）${default_name:+ [$default_name]}: " value
    RULE_NAME=${value:-$default_name}
    valid_name "$RULE_NAME" || die '名称格式无效'

    if [[ -n $default_protocol ]]; then
        prompt "协议 [tcp/udp/both，默认 $default_protocol]: " value
        RULE_PROTOCOL=${value:-$default_protocol}
        [[ $RULE_PROTOCOL == tcp || $RULE_PROTOCOL == udp || $RULE_PROTOCOL == both ]] \
            || die '协议必须是 tcp、udp 或 both'
    else
        choose_protocol
    fi

    if [[ -n $default_listen_start ]]; then
        listen_spec=$(port_target "$default_listen_start" "$default_listen_end")
    else
        listen_spec=''
    fi
    prompt "本机端口或范围（如 443 或 10000-10100）${listen_spec:+ [$listen_spec]}: " value
    value=${value:-$listen_spec}
    parse_port_spec "$value" || die '本机端口格式无效'
    RULE_LISTEN_START=$PORT_START
    RULE_LISTEN_END=$PORT_END

    prompt "对端 IPv4 或域名${default_target:+ [$default_target]}: " value
    RULE_TARGET=${value:-$default_target}
    RULE_TARGET=${RULE_TARGET,,}
    valid_ipv4 "$RULE_TARGET" || valid_domain "$RULE_TARGET" || die '对端地址格式无效'

    if [[ -n $default_target_start ]]; then
        target_spec=$(port_target "$default_target_start" "$default_target_end")
    else
        target_spec=$(port_target "$RULE_LISTEN_START" "$RULE_LISTEN_END")
    fi
    prompt "对端端口或范围${target_spec:+ [$target_spec]}: " value
    value=${value:-$target_spec}
    parse_port_spec "$value" || die '对端端口格式无效'
    RULE_TARGET_START=$PORT_START
    RULE_TARGET_END=$PORT_END
    ((RULE_LISTEN_END - RULE_LISTEN_START == RULE_TARGET_END - RULE_TARGET_START)) \
        || die '本机与对端端口范围必须包含相同数量的端口'

    RULE_IP=$(resolve_target "$RULE_TARGET") || die "无法解析对端地址：$RULE_TARGET"
}

next_id() {
    awk -F '\t' 'BEGIN { max=0 } $1+0 > max { max=$1+0 } END { print max+1 }' "$RULES_PATH"
}

add_rule() {
    local id
    collect_rule
    grep -Fq $'\t'"$RULE_NAME"$'\t' "$RULES_PATH" && die "名称已存在：$RULE_NAME"
    id=$(next_id)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$RULE_NAME" "$RULE_PROTOCOL" "$RULE_LISTEN_START" "$RULE_LISTEN_END" \
        "$RULE_TARGET" "$RULE_TARGET_START" "$RULE_TARGET_END" "$RULE_IP" >>"$RULES_PATH"
    is_enabled && apply_rules
    say "已新增：$RULE_NAME（$RULE_IP）"
}

show_rules() {
    if [[ ! -s $RULES_PATH ]]; then
        printf '  （暂无规则）\n'
        return
    fi
    awk -F '\t' '
        {
            lp=($4==$5 ? $4 : $4 "-" $5)
            rp=($7==$8 ? $7 : $7 "-" $8)
            printf "  %s) %s  %s  0.0.0.0:%s -> %s(%s):%s\n", $1, $2, $3, lp, $6, $9, rp
        }
    ' "$RULES_PATH"
}

modify_rule() {
    local selection record temp_path id name protocol listen_start listen_end target target_start target_end ip
    [[ -s $RULES_PATH ]] || { say '暂无可修改的规则'; return; }
    show_rules
    prompt '请输入要修改的编号: ' selection
    [[ $selection =~ ^[0-9]+$ ]] || die '编号无效'
    record=$(awk -F '\t' -v id="$selection" '$1 == id { print; exit }' "$RULES_PATH")
    [[ -n $record ]] || die '编号不存在'
    IFS=$'\t' read -r id name protocol listen_start listen_end target target_start target_end ip <<<"$record"
    collect_rule "$name" "$protocol" "$listen_start" "$listen_end" "$target" "$target_start" "$target_end"
    if [[ $RULE_NAME != "$name" ]] && grep -Fq $'\t'"$RULE_NAME"$'\t' "$RULES_PATH"; then
        die "名称已存在：$RULE_NAME"
    fi

    temp_path="$RULES_PATH.new.$$"
    awk -F '\t' -v OFS='\t' -v selected="$id" \
        -v name="$RULE_NAME" -v protocol="$RULE_PROTOCOL" \
        -v ls="$RULE_LISTEN_START" -v le="$RULE_LISTEN_END" \
        -v target="$RULE_TARGET" -v ts="$RULE_TARGET_START" \
        -v te="$RULE_TARGET_END" -v ip="$RULE_IP" '
        $1 == selected { print $1,name,protocol,ls,le,target,ts,te,ip; next }
        { print }
    ' "$RULES_PATH" >"$temp_path"
    chmod 600 "$temp_path"
    mv -f "$temp_path" "$RULES_PATH"
    is_enabled && apply_rules
    say "已修改：$RULE_NAME（$RULE_IP）"
}

status_text() {
    if is_enabled; then printf '已打开'; else printf '已关闭'; fi
}

show_menu() {
    local choice
    open_input
    while :; do
        printf '\nLinux 端口转发（IPv4）\n'
        printf '状态：%s\n' "$(status_text)"
        show_rules
        printf '\n  1) 打开端口转发\n'
        printf '  2) 关闭端口转发\n'
        printf '  3) 新增端口转发\n'
        printf '  4) 修改端口转发\n'
        printf '  0) 退出\n'
        prompt '请选择 [0-4]: ' choice
        case "$choice" in
            1) enable_forwarding ;;
            2) disable_forwarding ;;
            3) add_rule ;;
            4) modify_rule ;;
            0) return ;;
            *) say '无效选项' ;;
        esac
    done
}

usage() {
    cat <<EOF
用法：
  $PROGRAM              打开交互菜单
  $PROGRAM --sync       刷新域名解析，并按开关状态同步规则（供 cron 调用）
  $PROGRAM --help       显示帮助

配置仅保存在本机 $RULES_PATH，仓库脚本不包含转发地址或端口。
EOF
}

main() {
    need_root
    case "${1:-}" in
        --sync)
            command -v iptables >/dev/null 2>&1 || die '缺少 iptables'
            sync_rules
            ;;
        --help|-h)
            usage
            ;;
        '')
            install_service
            show_menu
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

if [[ ${PORT_FORWARD_TESTING:-0} != 1 ]]; then
    main "$@"
fi
