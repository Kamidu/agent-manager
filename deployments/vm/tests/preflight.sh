#!/usr/bin/env bash
# Cert/DNS pre-flight tests for lib-advanced.sh. Generates throwaway certs with openssl.
# Run: bash deployments/vm/tests/preflight.sh
# AMP_HOST_*/DOMAIN_BASE/AMP_AGENTS_BASE are consumed by sourced lib functions; the
# source boundary hides that from shellcheck, so disable the unused-var warning. The
# _resolve_host stubs are invoked indirectly by validate_dns (SC2329).
# shellcheck disable=SC2034,SC2329
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-advanced.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-advanced.sh"
# shellcheck source=../lib-vm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-vm.sh"
# shellcheck source=../lib-tls.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-tls.sh"

FAILLOG="$(mktemp)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$FAILLOG"' EXIT
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then printf 'ok   - %s\n' "$label"
  else printf 'FAIL - %s\n      expected: %q\n      actual:   %q\n' "$label" "$expected" "$actual"; echo 1 >>"$FAILLOG"; fi
}

# gen_cert <out-prefix> <days> <san-csv> — self-signed cert/key with the given SANs.
gen_cert() {
  local out="$1" days="$2" sans="$3" san_arg
  san_arg="DNS:${sans//,/,DNS:}"
  openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
    -keyout "${out}.key" -out "${out}.crt" -subj "/CN=test" \
    -addext "subjectAltName=${san_arg}" >/dev/null 2>&1
}

DOMAIN_BASE=amp.mycompany.com
AMP_AGENTS_BASE=agents.amp.mycompany.com
AMP_HOST_CONSOLE=console.amp.mycompany.com
AMP_HOST_API=api.amp.mycompany.com
AMP_HOST_THUNDER=thunder.amp.mycompany.com
AMP_HOST_OBSERVER=observer.amp.mycompany.com
AMP_HOST_GATEWAY=gateway.amp.mycompany.com
AMP_HOST_REGISTRY=registry.amp.mycompany.com
AMP_HOST_CP=cp.amp.mycompany.com

# Good cert: wildcard for services + wildcard for agents.
gen_cert "$TMP/good" 365 "*.amp.mycompany.com,*.agents.amp.mycompany.com"
validate_cert "$TMP/good.crt" "$TMP/good.key"; rc=$?
assert_eq "good cert validates rc=0" "0" "$rc"

# Missing agents SAN: must fail and name the agents wildcard.
gen_cert "$TMP/noagents" 365 "*.amp.mycompany.com"
validate_cert "$TMP/noagents.crt" "$TMP/noagents.key"; rc=$?
assert_eq "missing agents SAN rc=1" "1" "$rc"
assert_eq "names agents wildcard" "yes" \
  "$(printf '%s\n' "${CERT_ERRORS[@]}" | grep -qF '*.agents.amp.mycompany.com' && echo yes || echo no)"

# Mismatched key: cert from one keypair, key from another.
gen_cert "$TMP/other" 365 "*.amp.mycompany.com,*.agents.amp.mycompany.com"
validate_cert "$TMP/good.crt" "$TMP/other.key"; rc=$?
assert_eq "key mismatch rc=1" "1" "$rc"

# EC cert/key pair: the public-key comparison must work for non-RSA keys too
# (the old RSA-only modulus check would false-fail here).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
  -keyout "$TMP/ec.key" -out "$TMP/ec.crt" -subj "/CN=test" \
  -addext "subjectAltName=DNS:*.amp.mycompany.com,DNS:*.agents.amp.mycompany.com" >/dev/null 2>&1
validate_cert "$TMP/ec.crt" "$TMP/ec.key"; rc=$?
assert_eq "EC cert/key validates rc=0" "0" "$rc"

# Expired cert. -days must be positive on OpenSSL 3.x, so backdate explicitly with
# -not_before/-not_after (OpenSSL >=3.2). On older openssl these flags are absent and
# the cert won't actually be expired — skip the assertion rather than fail spuriously.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/expired.key" -out "$TMP/expired.crt" -subj "/CN=test" \
  -addext "subjectAltName=DNS:*.amp.mycompany.com,DNS:*.agents.amp.mycompany.com" \
  -not_before 20200101000000Z -not_after 20200102000000Z >/dev/null 2>&1 || true
if [[ -f "$TMP/expired.crt" ]] && ! openssl x509 -checkend 0 -noout -in "$TMP/expired.crt" >/dev/null 2>&1; then
  validate_cert "$TMP/expired.crt" "$TMP/expired.key"; rc=$?
  assert_eq "expired cert rc=1" "1" "$rc"
  assert_eq "names expiry" "yes" \
    "$(printf '%s\n' "${CERT_ERRORS[@]}" | grep -qiF 'expired' && echo yes || echo no)"
else
  printf 'skip - expired cert assertion (openssl lacks -not_before/-not_after backdating)\n'
fi

# --- validate_dns: stub the resolver so the test is hermetic ---
TLS_MODE=letsencrypt
# Stub: every host resolves to the expected IP.
_resolve_host() { echo "203.0.113.10"; }
validate_dns 203.0.113.10; rc=$?
assert_eq "LE all-resolve rc=0" "0" "$rc"

# Resolving to any one of several candidate IPs (local + public) passes. This is the
# NAT'd cloud-VM case: DNS points at the public IP, which is one of the candidates.
_resolve_host() { echo "203.0.113.10"; }
validate_dns 10.128.0.5 203.0.113.10; rc=$?
assert_eq "LE resolve-to-public-candidate rc=0" "0" "$rc"

# Stub: a host resolves to none of the candidates -> hard fail in letsencrypt.
_resolve_host() { echo "198.51.100.5"; }
validate_dns 10.128.0.5 203.0.113.10; rc=$?
assert_eq "LE wrong-resolve rc=1" "1" "$rc"

# Same wrong resolution is advisory (rc=0) in byoc/upstream.
TLS_MODE=byoc
validate_dns 203.0.113.10; rc=$?
assert_eq "byoc wrong-resolve advisory rc=0" "0" "$rc"
unset -f _resolve_host

# Every A record must point at this VM: a host with one rogue record fails (letsencrypt).
TLS_MODE=letsencrypt
_resolve_host() { printf '203.0.113.10\n198.51.100.5\n'; }
validate_dns 203.0.113.10; rc=$?
assert_eq "LE multi-record one-rogue rc=1" "1" "$rc"
# A host that doesn't resolve at all fails too.
_resolve_host() { echo ""; }
validate_dns 203.0.113.10; rc=$?
assert_eq "LE unresolved rc=1" "1" "$rc"
unset -f _resolve_host

# --- generate_selfsigned_ca: produces a CA + leaf whose SANs cover every host ---
generate_selfsigned_ca "$TMP/ssg" 365
assert_eq "selfsigned writes ca.crt"      "yes" "$([[ -f "$TMP/ssg/ca.crt" ]] && echo yes || echo no)"
assert_eq "selfsigned writes fullchain"   "yes" "$([[ -f "$TMP/ssg/fullchain.pem" ]] && echo yes || echo no)"
# validate_cert reads AMP_HOST_* (set at top of this file) + checks SAN coverage incl.
# the *.agents wildcard, so a passing rc proves the generated SANs are complete.
validate_cert "$TMP/ssg/fullchain.pem" "$TMP/ssg/privkey.pem"; rc=$?
assert_eq "selfsigned cert validates rc=0" "0" "$rc"
ssg_sans="$(openssl x509 -noout -ext subjectAltName -in "$TMP/ssg/fullchain.pem" 2>/dev/null)"
assert_eq "selfsigned covers agents wildcard" "yes" "$(grep -qF '*.agents.amp.mycompany.com' <<<"$ssg_sans" && echo yes || echo no)"

if [[ -s "$FAILLOG" ]]; then echo "PREFLIGHT TESTS FAILED"; exit 1; fi
echo "ALL PREFLIGHT TESTS PASSED"
