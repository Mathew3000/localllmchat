#!/usr/bin/env bash
# generate_cert.sh — create a self-signed CA + server certificate for LAN use.
#
# Run this once before `docker compose up`.
# Requires: openssl (available in WSL, Linux, macOS, Git Bash)
#
# Usage:
#   ./generate_cert.sh                   # auto-detect LAN IP
#   ./generate_cert.sh 192.168.1.50      # explicit single IP
#   ./generate_cert.sh 192.168.1.50 10.0.0.5  # multiple IPs
#
# To use your own existing certs instead, place them in ./certs/:
#   server.crt   — server certificate (or full chain)
#   server.key   — server private key
#   ca.crt       — CA certificate (bundle in Flutter app or install on devices)
# Then skip running this script.

set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)/certs"
DAYS=3650   # 10 years — rotate when needed
CN="LocalLLMChat"

mkdir -p "$CERT_DIR"

# ── Skip if certs already exist ───────────────────────────────────────────────
if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
  echo "Certs already exist in $CERT_DIR — skipping generation."
  echo "Delete server.crt and server.key to regenerate."
  exit 0
fi

# ── Collect IP SANs ───────────────────────────────────────────────────────────
EXTRA_IPS=("$@")

if [[ ${#EXTRA_IPS[@]} -eq 0 ]]; then
  # Auto-detect primary LAN IP
  if command -v ip &>/dev/null; then
    AUTO_IP=$(ip route get 1.1.1.1 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
      | head -1)
  elif command -v ipconfig &>/dev/null; then
    AUTO_IP=$(ipconfig 2>/dev/null \
      | awk '/IPv4/ {print $NF}' \
      | grep -v '^127' \
      | head -1)
  fi
  [[ -n "${AUTO_IP:-}" ]] && EXTRA_IPS=("$AUTO_IP")
fi

# ── Write OpenSSL config files ────────────────────────────────────────────────
CA_CNF="$CERT_DIR/_ca.cnf"
SRV_CNF="$CERT_DIR/_srv.cnf"

cat > "$CA_CNF" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
[dn]
CN = $CN CA
[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
EOF

{
  echo "[req]"
  echo "distinguished_name = dn"
  echo "req_extensions     = v3_req"
  echo "prompt             = no"
  echo "[dn]"
  echo "CN = $CN"
  echo "[v3_req]"
  echo "subjectAltName   = @alt_names"
  echo "keyUsage         = digitalSignature, keyEncipherment"
  echo "extendedKeyUsage = serverAuth"
  echo "[alt_names]"
  echo "DNS.1 = localhost"
  echo "IP.1  = 127.0.0.1"
  idx=2
  for ip in "${EXTRA_IPS[@]}"; do
    echo "IP.$idx = $ip"
    (( idx++ ))
  done
} > "$SRV_CNF"

# ── Generate CA key + self-signed certificate ─────────────────────────────────
echo "Generating CA..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -new -x509 \
  -days "$DAYS" \
  -key  "$CERT_DIR/ca.key" \
  -out  "$CERT_DIR/ca.crt" \
  -config "$CA_CNF"

# ── Generate server key + CSR + sign with CA ─────────────────────────────────
echo "Generating server cert..."
openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null
openssl req -new \
  -key    "$CERT_DIR/server.key" \
  -out    "$CERT_DIR/server.csr" \
  -config "$SRV_CNF"
openssl x509 -req \
  -days "$DAYS" \
  -in   "$CERT_DIR/server.csr" \
  -CA   "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -out  "$CERT_DIR/server.crt" \
  -extensions v3_req \
  -extfile "$SRV_CNF" 2>/dev/null

# ── Cleanup temps ─────────────────────────────────────────────────────────────
rm -f "$CERT_DIR/server.csr" "$CERT_DIR/ca.srl" "$CA_CNF" "$SRV_CNF"
chmod 600 "$CERT_DIR/server.key" "$CERT_DIR/ca.key"

echo ""
echo "Done! Files written to $CERT_DIR/"
echo ""
echo "  ca.crt      — install on your devices OR bundle in the Flutter app"
echo "  server.crt  — mounted into the Caddy container"
echo "  server.key  — mounted into the Caddy container (keep private!)"
echo ""
if [[ ${#EXTRA_IPS[@]} -gt 0 ]]; then
  echo "Cert SANs: localhost, 127.0.0.1, ${EXTRA_IPS[*]}"
else
  echo "Cert SANs: localhost, 127.0.0.1 only."
  echo "Next time pass your LAN IP as an argument: ./generate_cert.sh 192.168.x.x"
fi
echo ""
echo "Next step: docker compose up --build"
