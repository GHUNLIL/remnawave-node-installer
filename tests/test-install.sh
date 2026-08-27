#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_SECRET="test_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'TEST FAILED: %s\n' "$*" >&2
  exit 1
}

OUTPUT="$({
  REMNAWAVE_DRY_RUN=1 \
  REMNAWAVE_INSTALL_DIR="${TEST_ROOT}/node" \
  REMNAWAVE_SECRET_KEY="$TEST_SECRET" \
    bash "${SCRIPT_DIR}/install.sh" --port 2222
} 2>&1)"

[[ "$OUTPUT" != *"$TEST_SECRET"* ]] || fail "SECRET_KEY leaked to output"
[[ -f "${TEST_ROOT}/node/.env" ]] || fail ".env was not created"
[[ -f "${TEST_ROOT}/node/docker-compose.yml" ]] || fail "compose file was not created"
[[ "$(stat -c '%a' "${TEST_ROOT}/node")" == "700" ]] || fail "install directory mode is not 700"
[[ "$(stat -c '%a' "${TEST_ROOT}/node/.env")" == "600" ]] || fail ".env mode is not 600"
[[ "$(stat -c '%a' "${TEST_ROOT}/node/docker-compose.yml")" == "600" ]] || fail "compose mode is not 600"
grep -Fqx "NODE_PORT=2222" "${TEST_ROOT}/node/.env" || fail "NODE_PORT missing from .env"
grep -Fqx "SECRET_KEY=${TEST_SECRET}" "${TEST_ROOT}/node/.env" || fail "SECRET_KEY missing from .env"
grep -Fq "\${SECRET_KEY:?SECRET_KEY is required}" "${TEST_ROOT}/node/docker-compose.yml" || fail "compose does not reference SECRET_KEY"
if grep -Fq "$TEST_SECRET" "${TEST_ROOT}/node/docker-compose.yml"; then
  fail "SECRET_KEY leaked to compose file"
fi

if REMNAWAVE_DRY_RUN=1 REMNAWAVE_INSTALL_DIR="${TEST_ROOT}/bad-key" REMNAWAVE_SECRET_KEY="short" \
  bash "${SCRIPT_DIR}/install.sh" >/dev/null 2>&1; then
  fail "invalid short SECRET_KEY was accepted"
fi

if REMNAWAVE_DRY_RUN=1 REMNAWAVE_INSTALL_DIR="${TEST_ROOT}/bad-port" REMNAWAVE_SECRET_KEY="$TEST_SECRET" \
  bash "${SCRIPT_DIR}/install.sh" --port 70000 >/dev/null 2>&1; then
  fail "invalid port was accepted"
fi

printf 'All tests passed.\n'
