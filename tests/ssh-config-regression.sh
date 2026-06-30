#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf '[ssh-config-test] FAIL: %s\n' "$*" >&2
  exit 1
}

effective_value() {
  local key="$1"
  local name="$2"
  ssh -F "$SSH_CONFIG" -G "$name" 2>/dev/null |
    awk -v key="$key" '$1 == key { print $2; exit }'
}

(
  export HOME="$TMP/home"
  mkdir -p "$HOME/.ssh"
  # shellcheck source=../sandbox
  source "$ROOT/sandbox" >/dev/null

  local_name="sandbox-ssh-regression"
  local_port="29990"
  write_ssh_config "$local_name" agent "$local_port"

  [ "$(effective_value hostname "$local_name")" = "127.0.0.1" ] ||
    fail "fixture did not initially resolve through the managed include"

  # Reproduce the June 26 edit exactly: a new Host stanza was inserted above
  # the existing Include, making OpenSSH scope that Include to bluefin.
  cat >"$SSH_CONFIG" <<EOF
Host bluefin
    HostName 100.72.144.88
    User jacob

Include $SSH_MANAGED_CONFIG
EOF

  [ "$(effective_value hostname "$local_name")" = "$local_name" ] ||
    fail "negative control did not reproduce the broken alias"
  [ "$(effective_value port "$local_name")" = "22" ] ||
    fail "negative control unexpectedly retained the managed port"

  # This is the same repair path used by create, update, start, doctor, and ssh.
  write_ssh_config "$local_name" agent "$local_port"

  [ "$(sed -n '1p' "$SSH_CONFIG")" = "Include $SSH_MANAGED_CONFIG" ] ||
    fail "managed Include was not restored to the first line"
  [ "$(grep -Fxc "Include $SSH_MANAGED_CONFIG" "$SSH_CONFIG")" -eq 1 ] ||
    fail "managed Include was not deduplicated"
  [ "$(effective_value hostname "$local_name")" = "127.0.0.1" ] ||
    fail "sandbox alias does not resolve to localhost after repair"
  [ "$(effective_value user "$local_name")" = "agent" ] ||
    fail "sandbox alias has the wrong user after repair"
  [ "$(effective_value port "$local_name")" = "$local_port" ] ||
    fail "sandbox alias has the wrong port after repair"
  [ "$(effective_value hostname bluefin)" = "100.72.144.88" ] ||
    fail "repair damaged the unrelated bluefin stanza"

  # Idempotency: re-running repair on an already-canonical config must not
  # change the file (no duplicate Includes, no reordering).
  cp "$SSH_CONFIG" "$TMP/canonical-snapshot"
  write_ssh_config "$local_name" agent "$local_port"
  cmp -s "$SSH_CONFIG" "$TMP/canonical-snapshot" ||
    fail "repair mutated an already-canonical config (not idempotent)"
  [ "$(grep -Fxc "Include $SSH_MANAGED_CONFIG" "$SSH_CONFIG")" -eq 1 ] ||
    fail "idempotent re-run duplicated the Include"

  # Match-block scoping: OpenSSH scopes an Include inside a Match block the
  # same way as Host. Repair must pull it back to the top level.
  cat >"$SSH_CONFIG" <<EOF
Match host bluefin
    HostName 100.72.144.88

Include $SSH_MANAGED_CONFIG
EOF
  [ "$(effective_value hostname "$local_name")" = "$local_name" ] ||
    fail "Match-scoped include did not break the alias (negative control)"
  write_ssh_config "$local_name" agent "$local_port"
  [ "$(sed -n '1p' "$SSH_CONFIG")" = "Include $SSH_MANAGED_CONFIG" ] ||
    fail "repair did not promote the Match-scoped Include to line 1"
  [ "$(grep -Fxc "Include $SSH_MANAGED_CONFIG" "$SSH_CONFIG")" -eq 1 ] ||
    fail "repair left a duplicate Include after Match-block repair"
  [ "$(effective_value hostname "$local_name")" = "127.0.0.1" ] ||
    fail "sandbox alias does not resolve after Match-block repair"
)

printf '[ssh-config-test] PASS\n'
