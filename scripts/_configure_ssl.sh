#!/bin/bash

log "Starting SSL configuration"

SSL_V3_EXT_FILE="$SSL_CERTS_DIR/v3.ext"
SSL_ROOT_CN="pg-root-ca.railway.com"
SSL_ROOT_SUBJ="/C=US/O=Railway Corporation/CN=${SSL_ROOT_CN}"
SSL_ROOT_CA_EXPIRY_DAYS=7300
SSL_ROOT_CSR="$SSL_CERTS_DIR/root.csr"
SSL_ROOT_CRT="$SSL_CERTS_DIR/root.crt"
SSL_ROOT_KEY="$SSL_CERTS_DIR/root.key"
SSL_SERVER_CERT_CN="localhost"
SSL_SERVER_CERT_EXPIRY_DAYS=730
SSL_SERVER_CSR="$SSL_CERTS_DIR/server.csr"
SSL_SERVER_CRT="$SSL_CERTS_DIR/server.crt"
SSL_SERVER_KEY="$SSL_CERTS_DIR/server.key"

if [ -z "$SSL_CERT_DAYS" ]; then
  log_warn "\
'SSL_CERT_DAYS' is deprecated. This value will be ignored. All certificates \
default to 730 days expiry."
fi

if [ ! -f "$SSL_SERVER_CRT" ]; then
  log "SSL: Server certificate is missing. Generating ⏳"

  # Generate root CSR
  log "SSL: Generating Certificate Signing Request (CSR) for Root CA ⏳"
  openssl req \
    -new \
    -nodes \
    -text \
    -subj "${SSL_ROOT_SUBJ}" \
    -keyout ${SSL_ROOT_KEY} \
    -out ${SSL_ROOT_CSR} \
    2>&1
  chmod og-rwx "$SSL_ROOT_KEY"
  chmod og-rwx "$SSL_ROOT_CSR"

  # Use CSR to generate root x509v3 CA
  log "SSL: Generating x509v3 Root CA certificate ⏳"
  cat >|"$SSL_V3_EXT_FILE" <<EOF
[v3_ca_req]
authorityKeyIdentifier = keyid, issuer
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = DNS:${SSL_ROOT_CN}
EOF
  openssl x509 \
    -req \
    -text \
    -in ${SSL_ROOT_CSR} \
    -days ${SSL_ROOT_CA_EXPIRY_DAYS} \
    -extfile ${SSL_V3_EXT_FILE} \
    -extensions v3_ca_req \
    -signkey ${SSL_ROOT_KEY} \
    -out ${SSL_ROOT_CRT} \
    2>&1
  chmod og-rwx "$SSL_ROOT_CRT"

  # Create new server cert signed by root CA
  log "SSL: Generating private key for server certificate ⏳"
  openssl req \
    -new \
    -nodes \
    -text \
    -subj "/CN=${SSL_SERVER_CERT_CN}" \
    -keyout ${SSL_SERVER_KEY} \
    -out ${SSL_SERVER_CSR} \
    2>&1
  chmod og-rwx ${SSL_SERVER_KEY}
  chmod og-rwx ${SSL_SERVER_CSR}

  log "SSL: Generating server certificate ⏳"
  openssl x509 \
    -req \
    -in ${SSL_SERVER_CSR} \
    -text \
    -days ${SSL_SERVER_CERT_EXPIRY_DAYS} \
    -CA ${SSL_ROOT_CRT} \
    -CAkey ${SSL_ROOT_KEY} \
    -CAcreateserial \
    -out ${SSL_SERVER_CRT} \
    2>&1
  chmod og-rwx ${SSL_SERVER_CRT}

  log_ok "SSL: Server certificate has been successfully generated."
else
  server_cert_exp=$(
    openssl x509 \
      -enddate \
      -noout \
      -in "$SSL_CERTS_DIR/server.crt" |
      cut -d= -f2
  )
  log "SSL: Server certificate will expire on $server_cert_exp."

  if ! openssl x509 -checkend 0 -in "$SSL_CERTS_DIR/server.crt" >/dev/null; then
    log_warn "SSL: Server certificate is expiring. Renewing ⏳"
    openssl x509 \
      -req \
      -in ${SSL_SERVER_CSR} \
      -text \
      -days ${SSL_SERVER_CERT_EXPIRY_DAYS} \
      -CA ${SSL_ROOT_CRT} \
      -CAkey ${SSL_ROOT_KEY} \
      -CAcreateserial \
      -out ${SSL_SERVER_CRT} \
      2>&1
    chmod og-rwx ${SSL_SERVER_CRT}
    log_ok "SSL: Server certificate has been successfully renewed."
  fi
  log_ok "SSL: Server certificate is valid."
fi

if ! grep -q "ssl = on" "$PG_CONF_FILE"; then
  cat >>"$PG_CONF_FILE" <<EOF
# Added by Railway on $(date +'%Y-%m-%d %H:%M:%S') [via: $SH_CONFIGURE_SSL]
ssl = on
ssl_ca_file = '$SSL_ROOT_CRT'
ssl_key_file = '$SSL_SERVER_KEY'
ssl_cert_file = '$SSL_SERVER_CRT'
EOF
  log_ok "SSL: Postgres configured with ssl=on."
else
  log_ok "SSL: Postgres configured with ssl=on."
fi

sudo chown -R postgres:postgres "$SSL_CERTS_DIR"
sudo chmod 700 "$SSL_CERTS_DIR"
