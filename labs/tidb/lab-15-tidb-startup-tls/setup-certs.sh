#!/usr/bin/env bash
# setup-certs.sh - generate a self-signed CA plus one shared server cert/key
# suitable for inter-component TLS in lab-15.
#
# Output (all in ./certs/):
#   ca.pem          - self-signed CA
#   ca-key.pem      - CA private key
#   server.pem      - server cert signed by the CA
#   server-key.pem  - server private key
#   server.cnf      - openssl config used (kept for traceability)
#
# The server cert SANs cover:
#   - localhost, 127.0.0.1                    (phase 1 bare-process)
#   - pd-0, tikv-0, tidb-0, tiflash-0         (phase 3 multi-container)
# so the same CA + server cert pair works for both phases.
#
# Idempotent: if certs already exist in ${CERT_DIR}, this script is a no-op
# (delete the dir to force regeneration).
#
# Cert chain follows the pattern in TiDB's "Generate Self-Signed Certificates"
# doc: https://docs.pingcap.com/tidb/stable/generate-self-signed-certificates/
# but uses one shared server cert across the four components for simplicity.
# Real production deployments use per-component certs with distinct CNs and
# `cluster-verify-cn` enforcement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${CERT_DIR:-${SCRIPT_DIR}/certs}"

if [ -f "${CERT_DIR}/ca.pem" ] && [ -f "${CERT_DIR}/server.pem" ]; then
  echo "Certs already exist in ${CERT_DIR}. To regenerate, delete the dir first:"
  echo "  rm -rf '${CERT_DIR}'"
  exit 0
fi

mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

echo "=== Generating CA (4096-bit RSA, 10-year validity) ==="
openssl genrsa -out ca-key.pem 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca-key.pem -days 3650 -out ca.pem \
  -subj "/CN=lab15-ca/O=lab15"

echo "=== Generating server key (4096-bit RSA) ==="
openssl genrsa -out server-key.pem 4096 2>/dev/null

echo "=== Writing openssl config with SANs ==="
cat > server.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
CN = lab15-server
O  = lab15

[v3_req]
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = pd-0
DNS.3 = tikv-0
DNS.4 = tidb-0
DNS.5 = tiflash-0
IP.1  = 127.0.0.1
EOF

echo "=== Generating server CSR ==="
openssl req -new -key server-key.pem -out server.csr -config server.cnf

echo "=== Signing server cert with the CA (10-year validity) ==="
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out server.pem -days 3650 -extensions v3_req -extfile server.cnf 2>/dev/null

# Cleanup transient artifacts (CSR + serial); keep the cnf for traceability.
rm -f server.csr ca.srl

echo
echo "=== Done ==="
echo "Files in ${CERT_DIR}:"
ls -la "${CERT_DIR}"
echo
echo "Each TiDB component uses different [security] key names:"
echo
echo "  # tidb-server (in tidb.toml):"
echo "  [security]"
echo "  cluster-ssl-ca   = \"${CERT_DIR}/ca.pem\""
echo "  cluster-ssl-cert = \"${CERT_DIR}/server.pem\""
echo "  cluster-ssl-key  = \"${CERT_DIR}/server-key.pem\""
echo
echo "  # tikv-server (in tikv.toml):"
echo "  [security]"
echo "  ca-path   = \"${CERT_DIR}/ca.pem\""
echo "  cert-path = \"${CERT_DIR}/server.pem\""
echo "  key-path  = \"${CERT_DIR}/server-key.pem\""
echo
echo "  # pd-server (in pd.toml):"
echo "  [security]"
echo "  cacert-path = \"${CERT_DIR}/ca.pem\""
echo "  cert-path   = \"${CERT_DIR}/server.pem\""
echo "  key-path    = \"${CERT_DIR}/server-key.pem\""
echo
echo "  # tiflash (in tiflash.toml; snake_case, distinct from the others):"
echo "  [security]"
echo "  ca_path   = \"${CERT_DIR}/ca.pem\""
echo "  cert_path = \"${CERT_DIR}/server.pem\""
echo "  key_path  = \"${CERT_DIR}/server-key.pem\""
