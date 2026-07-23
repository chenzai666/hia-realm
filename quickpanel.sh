#!/usr/bin/env bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/chenzai666/hia-realm/main/install.sh"
TMP_SCRIPT=$(mktemp)
trap 'rm -f "$TMP_SCRIPT"' EXIT

if [[ ${EUID} -ne 0 ]]; then
    echo "[错误] 请使用 root 用户运行。"
    exit 1
fi

curl -fsSL --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$TMP_SCRIPT"
head -n 1 "$TMP_SCRIPT" | grep -qx '#!/usr/bin/env bash' || {
    echo "[错误] 下载的安装脚本无效。"
    exit 1
}

bash "$TMP_SCRIPT"
