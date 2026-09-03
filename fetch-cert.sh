#!/usr/bin/env bash
# Fetch a password-protected certificate and manage its cron refresh job.
# Certificate URL, credentials, and destination are supplied only at setup time.

set -u

INSTALL_PATH='/usr/local/bin/fetch-cert'
CONFIG_PATH='/etc/fetch-cert.conf'
LOG_PATH='/var/log/fetch-cert.log'
STATE_DIR='/var/lib/fetch-cert'
STATE_PATH='/var/lib/fetch-cert/last-success'
CRON_MARKER='# fetch-cert-managed'
PLATFORM=''
CRONTAB_PATH=''

say() {
  printf '%s %s\n' "$(date '+%F %T')" "$*"
}

die() {
  say "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  fetch-cert.sh --url URL --user USER --password PASSWORD --output FILE [--interval Nd]
  fetch-cert.sh --sync
  fetch-cert.sh --uninstall

首次配置或修改配置：
  --url URL             远端证书完整 URL
  --user USER           HTTP Basic Auth 用户名
  --password PASSWORD   HTTP Basic Auth 密码
  --output FILE         保存证书的本机完整路径
  --interval Nd         可选，更新间隔；例如 3d 为每 3 天，默认 7d

维护命令：
  --sync                按已保存的配置检查是否到期；供 cron 调用
  --uninstall           删除本脚本安装的 cron 任务、配置和程序副本
  --help                显示本帮助
EOF
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
    CRONTAB_PATH='/etc/cron.d/fetch-cert'
  else
    die '仅支持 Alpine Linux（apk）和 Debian/Ubuntu（apt-get）'
  fi
}

cron_is_running() {
  pidof cron >/dev/null 2>&1 || pidof crond >/dev/null 2>&1
}

install_dependencies() {
  case "$PLATFORM" in
    alpine) apk add --no-cache curl ca-certificates >/dev/null ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y --no-install-recommends curl ca-certificates cron >/dev/null
      ;;
  esac
}

validate_interval() {
  local value=$1
  [[ "$value" =~ ^[1-9][0-9]*d$ ]] \
    || die '--interval 必须是以 d 结尾的正整数，例如 3d 或 5d'
}

save_config() {
  umask 077
  {
    printf 'CERT_URL=%q\n' "$URL"
    printf 'CERT_USER=%q\n' "$USER"
    printf 'CERT_PASSWORD=%q\n' "$PASSWORD"
    printf 'CERT_OUTPUT=%q\n' "$OUTPUT"
    printf 'CERT_INTERVAL=%q\n' "$INTERVAL"
  } > "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
  say "配置已保存至: $CONFIG_PATH"
}

load_config() {
  [[ -r "$CONFIG_PATH" ]] || die "尚未配置，请先传入 --url、--user、--password 和 --output"
  # 配置仅由本脚本写入，权限为 root:root 600。
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
  [[ -n ${CERT_URL:-} && -n ${CERT_USER:-} && -n ${CERT_PASSWORD:-} && -n ${CERT_OUTPUT:-} && -n ${CERT_INTERVAL:-} ]] \
    || die "配置文件不完整: $CONFIG_PATH"
  validate_interval "$CERT_INTERVAL"
}

sync_certificate() {
  local force=${1:-0} output_dir output_name temp_file interval_days interval_seconds now last_success
  load_config
  command -v curl >/dev/null 2>&1 || die '缺少 curl'

  interval_days=${CERT_INTERVAL%d}
  interval_seconds=$((interval_days * 86400))
  now=$(date +%s)
  if [[ "$force" != 1 && -r "$STATE_PATH" ]]; then
    read -r last_success < "$STATE_PATH" || last_success=0
    if [[ "$last_success" =~ ^[0-9]+$ && $((now - last_success)) -lt $interval_seconds ]]; then
      say "尚未到更新周期：$CERT_INTERVAL"
      return 0
    fi
  fi

  output_dir=$(dirname -- "$CERT_OUTPUT")
  output_name=$(basename -- "$CERT_OUTPUT")
  mkdir -p -- "$output_dir"
  temp_file=$(mktemp "${output_dir}/.${output_name}.tmp.XXXXXX") \
    || die '无法创建临时文件'

  # 不解析或校验证书内容；只在下载成功后以原子方式更新目标文件。
  if curl --fail --location --silent --show-error \
      --user "${CERT_USER}:${CERT_PASSWORD}" \
      --output "$temp_file" \
      "$CERT_URL"; then
    mv -f -- "$temp_file" "$CERT_OUTPUT"
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$now" > "$STATE_PATH"
    chmod 600 "$STATE_PATH"
    say "已更新：$CERT_OUTPUT"
  else
    rm -f -- "$temp_file"
    die '获取证书失败'
  fi
}

install_program() {
  mkdir -p /usr/local/bin
  install -m 700 "$0" "$INSTALL_PATH"
}

install_cron() {
  local temp_cron
  mkdir -p "$(dirname -- "$LOG_PATH")"
  touch "$LOG_PATH"
  chmod 600 "$LOG_PATH"

  if [[ "$PLATFORM" == 'alpine' ]]; then
    mkdir -p /etc/crontabs
    touch "$CRONTAB_PATH"
    chmod 600 "$CRONTAB_PATH"
    sed -i "\|$CRON_MARKER$|d" "$CRONTAB_PATH"
    printf '%s %s --sync >>%s 2>&1 %s\n' \
      '17 * * * *' "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >> "$CRONTAB_PATH"
  else
    mkdir -p /etc/cron.d
    temp_cron="${CRONTAB_PATH}.new.$$"
    {
      printf '%s\n' 'SHELL=/bin/sh'
      printf '%s root %s --sync >>%s 2>&1 %s\n' \
        '17 * * * *' "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER"
    } > "$temp_cron"
    chmod 644 "$temp_cron"
    mv -f -- "$temp_cron" "$CRONTAB_PATH"
  fi
}

start_cron() {
  if [[ "$PLATFORM" == 'alpine' ]]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now cron >/dev/null 2>&1 || true
    fi
    cron_is_running || service cron start >/dev/null 2>&1 || true
  fi
}

setup() {
  need_root
  detect_platform
  install_dependencies
  save_config
  install_program
  sync_certificate 1
  install_cron
  start_cron
  say "定时任务已安装: $CRONTAB_PATH（每小时检查，到 $INTERVAL 后更新）"
}

uninstall() {
  need_root
  detect_platform
  if [[ "$PLATFORM" == 'alpine' ]]; then
    [[ -f "$CRONTAB_PATH" ]] && sed -i "\|$CRON_MARKER$|d" "$CRONTAB_PATH"
  else
    rm -f -- "$CRONTAB_PATH"
  fi
  rm -f -- "$CONFIG_PATH" "$INSTALL_PATH" "$LOG_PATH" "$STATE_PATH"
  rmdir -- "$STATE_DIR" 2>/dev/null || true
  say '已删除本脚本的 cron 任务、配置、日志和程序副本'
}

URL=''
USER=''
PASSWORD=''
OUTPUT=''
INTERVAL='7d'
ACTION='setup'

while (($#)); do
  case "$1" in
    --url) URL=${2-}; shift 2 ;;
    --user) USER=${2-}; shift 2 ;;
    --password) PASSWORD=${2-}; shift 2 ;;
    --output) OUTPUT=${2-}; shift 2 ;;
    --interval) INTERVAL=${2-}; shift 2 ;;
    --sync) ACTION='sync'; shift ;;
    --uninstall) ACTION='uninstall'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

case "$ACTION" in
  setup)
    [[ -n "$URL" && -n "$USER" && -n "$PASSWORD" && -n "$OUTPUT" ]] \
      || { usage >&2; exit 2; }
    validate_interval "$INTERVAL"
    setup
    ;;
  sync)
    need_root
    sync_certificate
    ;;
  uninstall) uninstall ;;
esac
