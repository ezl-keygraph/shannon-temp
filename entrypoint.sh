#!/bin/bash
set -euo pipefail

TARGET_UID="${SHANNON_HOST_UID:-}"
TARGET_GID="${SHANNON_HOST_GID:-}"
CURRENT_UID=$(id -u pentest 2>/dev/null || echo "")

if [ -n "$TARGET_UID" ] && [ "$TARGET_UID" != "$CURRENT_UID" ]; then
  userdel pentest 2>/dev/null || true
  groupdel pentest 2>/dev/null || true

  groupadd -g "$TARGET_GID" pentest
  useradd -u "$TARGET_UID" -g pentest -s /bin/bash -M pentest

  chown -R pentest:pentest /app/sessions /app/workspaces /tmp/.claude /tmp/.pi
fi

PROXY_CA_SRC="${SHANNON_PROXY_CA:-/run/keygraph/proxy-ca.crt}"
if [ -f "$PROXY_CA_SRC" ]; then
  mkdir -p /usr/local/share/ca-certificates
  cp "$PROXY_CA_SRC" /usr/local/share/ca-certificates/keygraph-proxy.crt
  chmod 0644 /usr/local/share/ca-certificates/keygraph-proxy.crt
  update-ca-certificates >/dev/null 2>&1 || true
  export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/keygraph-proxy.crt
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

  CHROMIUM_NSSDB="${HOME:-/tmp}/.pki/nssdb"
  mkdir -p "$CHROMIUM_NSSDB"
  certutil -d "sql:$CHROMIUM_NSSDB" -N --empty-password 2>/dev/null || true
  certutil -d "sql:$CHROMIUM_NSSDB" -A -t "C,," -n keygraph-proxy \
    -i /usr/local/share/ca-certificates/keygraph-proxy.crt 2>/dev/null || true
  chown -R pentest:pentest "$CHROMIUM_NSSDB" 2>/dev/null || true
fi

exec su -m pentest -c "exec $*"
