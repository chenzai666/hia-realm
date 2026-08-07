#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source <(sed '/^main_menu$/d' "$ROOT_DIR/install.sh")

if ! python3 -c 'pass' >/dev/null 2>&1 && command -v python >/dev/null 2>&1; then
    python3() { command python "$@"; }
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

NGINX_CONF="$TEST_DIR/nginx.conf"
NGINX_SSL_DIR="$TEST_DIR/nginx-ssl"
NGINX_CERT_DEFAULT="$NGINX_SSL_DIR/cert.crt"
NGINX_KEY_DEFAULT="$NGINX_SSL_DIR/private.key"
PANEL_SERVICE_FILE="$TEST_DIR/realm-panel.service"
PANEL_SERVICE="realm-panel.service"

mkdir -p "$NGINX_SSL_DIR"
touch "$NGINX_CERT_DEFAULT" "$NGINX_KEY_DEFAULT"

write_nginx_config() {
    cat > "$NGINX_CONF" <<'EOF'
events { worker_connections 16; }
http {
}
EOF
}

write_panel_service() {
    cat > "$PANEL_SERVICE_FILE" <<'EOF'
[Service]
Environment="PANEL_USER=admin"
Environment="PANEL_PASS=test-password"
Environment="PANEL_PORT=4794"
Environment="PANEL_HOST=0.0.0.0"
Environment="PANEL_CERT=/root/ygkkkca/cert.crt"
Environment="PANEL_KEY=/root/ygkkkca/private.key"
EOF
}

systemctl() {
    [[ "${SYSTEMCTL_FAIL:-}" != "$*" ]]
}
nginx() { return 0; }
check_root() { return 0; }
install_nginx_dep() { return 0; }
ensure_nginx_main_conf() { return 0; }
install_base_deps() { return 0; }
need_cmd() { return 0; }
write_panel() { return 0; }
get_local_ip() { printf '%s\n' '203.0.113.10'; }

write_nginx_config
write_panel_service
configure_nginx_proxy <<< $'panel.example.com\n443\n'

grep -qF 'proxy_pass http://127.0.0.1:4794;' "$NGINX_CONF"
! grep -qF 'proxy_ssl_verify' "$NGINX_CONF"
grep -qF 'Environment="PANEL_HOST=127.0.0.1"' "$PANEL_SERVICE_FILE"
grep -qF 'Environment="PANEL_CERT="' "$PANEL_SERVICE_FILE"
grep -qF 'Environment="PANEL_KEY="' "$PANEL_SERVICE_FILE"
! find "$TEST_DIR" -name 'realm-panel.service.bak.*' -print -quit | grep -q .

if configure_panel_tls </dev/null; then
    echo '反代模式不应允许配置面板 IP 证书。' >&2
    exit 1
fi

write_panel_service
install_panel

grep -qF 'Environment="PANEL_HOST=127.0.0.1"' "$PANEL_SERVICE_FILE"
grep -qF 'Environment="PANEL_CERT="' "$PANEL_SERVICE_FILE"
grep -qF 'Environment="PANEL_KEY="' "$PANEL_SERVICE_FILE"

[[ "$PANEL_CERT_DEFAULT" != '/root/ygkkkca/cert.crt' ]]
[[ "$PANEL_KEY_DEFAULT" != '/root/ygkkkca/private.key' ]]

write_nginx_config
write_panel_service
SYSTEMCTL_FAIL='restart realm-panel.service'
if configure_nginx_proxy <<< $'panel.example.com\n443\n'; then
    echo '面板重启失败时反代配置不应成功。' >&2
    exit 1
fi
unset SYSTEMCTL_FAIL

! grep -qF '# BEGIN REALM_PANEL_PROXY' "$NGINX_CONF"
grep -qF 'Environment="PANEL_HOST=0.0.0.0"' "$PANEL_SERVICE_FILE"
grep -qF 'Environment="PANEL_CERT=/root/ygkkkca/cert.crt"' "$PANEL_SERVICE_FILE"
grep -qF 'Environment="PANEL_KEY=/root/ygkkkca/private.key"' "$PANEL_SERVICE_FILE"
! find "$TEST_DIR" -name 'realm-panel.service.bak.*' -print -quit | grep -q .

echo 'proxy mode tests passed'
