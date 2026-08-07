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

[[ "$PANEL_CERT_DEFAULT" == '/etc/panel-ssl/cert.crt' ]]
[[ "$PANEL_KEY_DEFAULT" == '/etc/panel-ssl/private.key' ]]
PANEL_CERT_LEGACY_DEFAULT="$TEST_DIR/realm/panel-ssl/cert.crt"
PANEL_KEY_LEGACY_DEFAULT="$TEST_DIR/realm/panel-ssl/private.key"
PANEL_CERT_DEFAULT="$TEST_DIR/etc/panel-ssl/cert.crt"
PANEL_KEY_DEFAULT="$TEST_DIR/etc/panel-ssl/private.key"
mkdir -p "$(dirname "$PANEL_CERT_LEGACY_DEFAULT")"
printf '%s\n' 'legacy certificate' > "$PANEL_CERT_LEGACY_DEFAULT"
printf '%s\n' 'legacy private key' > "$PANEL_KEY_LEGACY_DEFAULT"
realm_cert_pair=$(migrate_legacy_panel_certificate "$PANEL_CERT_LEGACY_DEFAULT" "$PANEL_KEY_LEGACY_DEFAULT")
[[ "$realm_cert_pair" == "${PANEL_CERT_DEFAULT}|${PANEL_KEY_DEFAULT}" ]]
cmp -s "$PANEL_CERT_LEGACY_DEFAULT" "$PANEL_CERT_DEFAULT"
cmp -s "$PANEL_KEY_LEGACY_DEFAULT" "$PANEL_KEY_DEFAULT"

ACME_BIN="$TEST_DIR/acme/acme.sh"
ACME_CONF="$TEST_DIR/acme/1.1.1.1/1.1.1.1.conf"
mkdir -p "$(dirname "$ACME_CONF")"
touch "$ACME_BIN"
chmod +x "$ACME_BIN"
cat > "$ACME_CONF" <<'EOF'
Le_RealKeyPath='/etc/realm/panel-ssl/private.key'
Le_RealFullChainPath='/etc/realm/panel-ssl/cert.crt'
EOF
get_cert_ip_from_file() { printf '%s\n' '1.1.1.1'; }
find_acme_sh() { printf '%s\n' "$ACME_BIN"; }
sync_acme_certificate_install_path "$PANEL_CERT_DEFAULT" "$PANEL_KEY_DEFAULT"
grep -qF "Le_RealKeyPath='${PANEL_KEY_DEFAULT}'" "$ACME_CONF"
grep -qF "Le_RealFullChainPath='${PANEL_CERT_DEFAULT}'" "$ACME_CONF"

mkdir -p "$NGINX_SSL_DIR"
touch "$NGINX_CERT_DEFAULT" "$NGINX_KEY_DEFAULT"

validate_domain_name 'panel.example.com'
! validate_domain_name 'panel.example.com;include'
validate_certificate_path "$NGINX_CERT_DEFAULT"

if command -v openssl >/dev/null 2>&1 && openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
    MATCH_CERT="$TEST_DIR/matching.crt"
    MATCH_KEY="$TEST_DIR/matching.key"
    CERT_SUBJECT='/CN=panel.example.com'
    [[ -n "${MSYSTEM:-}" ]] && CERT_SUBJECT='//CN=panel.example.com'
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "$CERT_SUBJECT" \
        -addext 'subjectAltName=DNS:panel.example.com' \
        -keyout "$MATCH_KEY" -out "$MATCH_CERT" >/dev/null 2>&1
    certificate_matches_domain "$MATCH_CERT" 'panel.example.com'
    ! certificate_matches_domain "$MATCH_CERT" 'other.example.com'
    cp "$MATCH_CERT" "$NGINX_CERT_DEFAULT"
    cp "$MATCH_KEY" "$NGINX_KEY_DEFAULT"
else
    certificate_matches_domain() { return 0; }
fi

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
configure_nginx_proxy <<< $'panel.example.com\n443\n\n\n'

grep -qF 'proxy_pass http://127.0.0.1:4794;' "$NGINX_CONF"
grep -qF "ssl_certificate ${NGINX_CERT_DEFAULT};" "$NGINX_CONF"
grep -qF "ssl_certificate_key ${NGINX_KEY_DEFAULT};" "$NGINX_CONF"
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

CUSTOM_CERT="$TEST_DIR/custom-domain.crt"
CUSTOM_KEY="$TEST_DIR/custom-domain.key"
cp "$NGINX_CERT_DEFAULT" "$CUSTOM_CERT"
cp "$NGINX_KEY_DEFAULT" "$CUSTOM_KEY"
configure_nginx_proxy <<< $'panel.example.com\n443\n'"$CUSTOM_CERT"$'\n'"$CUSTOM_KEY"$'\n'
grep -qF "ssl_certificate ${CUSTOM_CERT};" "$NGINX_CONF"
grep -qF "ssl_certificate_key ${CUSTOM_KEY};" "$NGINX_CONF"

write_nginx_config
write_panel_service
SYSTEMCTL_FAIL='restart realm-panel.service'
if configure_nginx_proxy <<< $'panel.example.com\n443\n\n\n'; then
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
