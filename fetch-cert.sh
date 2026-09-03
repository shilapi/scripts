#!/usr/bin/env bash
# Download a certificate from a password-protected URL and keep it refreshed.
# All connection details are supplied at runtime; none are embedded here.

set -u

usage() {
  cat <<'EOF'
用法：
  fetch-cert.sh --url URL --user USER --password PASSWORD --output FILE [--interval SECONDS]

参数：
  --url URL             远端证书完整 URL
  --user USER           HTTP Basic Auth 用户名
  --password PASSWORD   HTTP Basic Auth 密码
  --output FILE         保存到本机的完整文件路径
  --interval SECONDS    更新间隔（秒）；不传则只获取一次
  --help                显示本帮助

示例：
  sudo ./fetch-cert.sh \\
    --url 'https://example.invalid/cert/fullchain.cer' \\
    --user 'my-user' \\
    --password 'my-password' \\
    --output '/etc/ssl/example/fullchain.cer' \\
    --interval 86400
EOF
}

URL=''
USER=''
PASSWORD=''
OUTPUT=''
INTERVAL=''

while (($#)); do
  case "$1" in
    --url) URL=${2-}; shift 2 ;;
    --user) USER=${2-}; shift 2 ;;
    --password) PASSWORD=${2-}; shift 2 ;;
    --output) OUTPUT=${2-}; shift 2 ;;
    --interval) INTERVAL=${2-}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$URL" || -z "$USER" || -z "$PASSWORD" || -z "$OUTPUT" ]]; then
  echo '缺少必要参数。' >&2
  usage >&2
  exit 2
fi

if [[ -n "$INTERVAL" && ! "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  echo '--interval 必须是大于 0 的整数秒数。' >&2
  exit 2
fi

download() {
  local output_dir output_name temp_file
  output_dir=$(dirname -- "$OUTPUT")
  output_name=$(basename -- "$OUTPUT")

  mkdir -p -- "$output_dir"
  temp_file=$(mktemp "${output_dir}/.${output_name}.tmp.XXXXXX") || return 1

  # 先下载到同目录临时文件，成功后原子替换，避免读取到半份证书。
  if curl --fail --location --silent --show-error \
      --user "${USER}:${PASSWORD}" \
      --output "$temp_file" \
      "$URL"; then
    mv -f -- "$temp_file" "$OUTPUT"
    printf '%s 已更新：%s\n' "$(date '+%F %T')" "$OUTPUT"
  else
    rm -f -- "$temp_file"
    printf '%s 获取失败：%s\n' "$(date '+%F %T')" "$URL" >&2
    return 1
  fi
}

if [[ -z "$INTERVAL" ]]; then
  download
  exit $?
fi

while :; do
  download || true
  sleep "$INTERVAL"
done
