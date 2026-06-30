#!/usr/bin/env bash
set -euo pipefail

SANDBOX_BIN="${SANDBOX_BIN:-sandbox}"
RUN_ID="${SANDBOX_ACCEPTANCE_RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"
PRIMARY="sandbox-accept-${RUN_ID}"
PUBLIC_COPY="sandbox-public-${RUN_ID}"
IMPORTED="sandbox-import-${RUN_ID}"
TEST_USER="sandboxaccept"
TMP="$(mktemp -d)"
ARCHIVE="$TMP/${PRIMARY}.tar.gz"
LOG="$TMP/acceptance.log"
CREATED_NAMES=()

log() { printf '[acceptance] %s\n' "$*"; }
fail() { printf '[acceptance] FAIL: %s\n' "$*" >&2; exit 1; }

instance_exists() {
  lxc info "$1" >/dev/null 2>&1
}

destroy_if_present() {
  local name="$1"
  if instance_exists "$name"; then
    printf '%s\n' "$name" | "$SANDBOX_BIN" destroy "$name" >>"$LOG" 2>&1 || true
  fi
}

cleanup() {
  local status=$?
  local name
  set +e
  for name in "${CREATED_NAMES[@]}"; do
    destroy_if_present "$name"
  done
  if [ "$status" -ne 0 ]; then
    printf '[acceptance] retained log: %s\n' "$LOG" >&2
    tail -n 80 "$LOG" >&2
  else
    rm -rf "$TMP"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

run() {
  log "$*"
  "$@" >>"$LOG" 2>&1
}

box_env() {
  printf '%s/.ai-sandbox/boxes/%s.env\n' "$HOME" "$1"
}

env_value() {
  local name="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$(box_env "$name")"
}

find_port_base() {
  local base port reserved env
  for base in $(seq 30000 10 50000); do
    reserved=0
    for port in "$base" "$((base + 1))" "$((base + 2))"; do
      if ss -H -ltn "sport = :$port" | grep -q .; then
        reserved=1
        break
      fi
    done
    if [ "$reserved" -eq 0 ]; then
      for env in "$HOME"/.ai-sandbox/boxes/*.env; do
        [ -f "$env" ] || continue
        if grep -Fxq "PORT_BASE=$base" "$env"; then
          reserved=1
          break
        fi
      done
    fi
    [ "$reserved" -eq 0 ] && { printf '%s\n' "$base"; return; }
  done
  return 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_ssh() {
  local name="$1"
  local actual
  actual="$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 "$name" hostname)" ||
    fail "ssh $name failed"
  assert_eq "$name" "$actual" "ssh $name hostname"
}

assert_http() {
  local url="$1"
  timeout 15 curl -fsS "$url" >/dev/null || fail "HTTP check failed: $url"
}

assert_destroyed() {
  local name="$1"
  ! instance_exists "$name" || fail "$name still exists after destroy"
  [ ! -e "$(box_env "$name")" ] || fail "$name host mirror remains after destroy"
  [ ! -e "$HOME/.ai-sandbox/ssh/${name}_ed25519" ] || fail "$name private key remains after destroy"
  ! grep -Fq "# >>> ai-sandbox $name" "$HOME/.ai-sandbox/ssh/config" ||
    fail "$name managed SSH block remains after destroy"
  ! ssh-keygen -F "ai-sandbox-$name" -f "$HOME/.ai-sandbox/ssh/known_hosts" >/dev/null ||
    fail "$name managed known-host entry remains after destroy"
}

for command in create update start stop copy export github doctor view ssh list destroy; do
  run "$SANDBOX_BIN" help "$command"
done

command -v "$SANDBOX_BIN" >/dev/null || fail "sandbox command not installed"
command -v lxc >/dev/null || fail "lxc is unavailable"
command -v gh >/dev/null || fail "gh is unavailable"
run gh auth status

PORT_BASE="$(find_port_base)" || fail "could not find a free test port block"

log "creating a clean sandbox (this is the slowest phase)"
for name in "$PRIMARY" "$PUBLIC_COPY" "$IMPORTED"; do
  ! instance_exists "$name" || fail "refusing to reuse existing instance $name"
done
CREATED_NAMES+=("$PRIMARY")
run "$SANDBOX_BIN" create "$PRIMARY" \
  --user "$TEST_USER" \
  --port-base "$PORT_BASE" \
  --memory 8GiB \
  --github

assert_eq RUNNING "$(lxc list "$PRIMARY" --format csv -c s)" "create state"
assert_eq 8GiB "$(lxc config get "$PRIMARY" limits.memory)" "memory limit"
assert_eq "$TEST_USER" "$(env_value "$PRIMARY" SANDBOX_USER)" "custom user"
assert_eq "$PORT_BASE" "$(env_value "$PRIMARY" PORT_BASE)" "explicit port base"
assert_ssh "$PRIMARY"
assert_eq "$PRIMARY" "$(timeout 15 "$SANDBOX_BIN" ssh "$PRIMARY" -- hostname)" "sandbox ssh"
assert_http "$("$SANDBOX_BIN" view "$PRIMARY")"
assert_http "http://127.0.0.1:$((PORT_BASE + 2))/status"
"$SANDBOX_BIN" list | grep -Fq "$PRIMARY" || fail "compact list omitted $PRIMARY"
"$SANDBOX_BIN" list "$PRIMARY" | grep -Fq "ssh $PRIMARY" || fail "detail list omitted SSH command"
run "$SANDBOX_BIN" doctor "$PRIMARY"

log "testing GitHub grant, authentication, and revoke"
run "$SANDBOX_BIN" github "$PRIMARY" --revoke
run "$SANDBOX_BIN" github "$PRIMARY"
run lxc exec "$PRIMARY" -- runuser -u "$TEST_USER" -- bash -lc \
  'status=0; out="$(ssh -T git@github.com 2>&1)" || status=$?; [ "$status" -eq 1 ] && grep -qi "successfully authenticated" <<<"$out"'
run "$SANDBOX_BIN" github "$PRIMARY" --revoke

log "testing stop and start"
run "$SANDBOX_BIN" stop "$PRIMARY"
assert_eq STOPPED "$(lxc list "$PRIMARY" --format csv -c s)" "stop state"
assert_eq false "$(lxc config get "$PRIMARY" boot.autostart)" "stop autostart"
if timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=3 "$PRIMARY" true >/dev/null 2>&1; then
  fail "ssh unexpectedly succeeded while $PRIMARY was stopped"
fi
run "$SANDBOX_BIN" start "$PRIMARY"
assert_eq RUNNING "$(lxc list "$PRIMARY" --format csv -c s)" "start state"
assert_eq true "$(lxc config get "$PRIMARY" boot.autostart)" "start autostart"
assert_ssh "$PRIMARY"

log "testing update as a repair operation"
run lxc exec "$PRIMARY" -- bash -lc \
  'systemctl disable --now sandbox-novnc.service; rm -f /usr/local/bin/deskbot'
run "$SANDBOX_BIN" update "$PRIMARY"
run lxc exec "$PRIMARY" -- bash -lc \
  'systemctl is-enabled --quiet sandbox-novnc.service; systemctl is-active --quiet sandbox-novnc.service; test -x /usr/local/bin/deskbot'
assert_ssh "$PRIMARY"

log "testing stop, public copy, and external binds"
run "$SANDBOX_BIN" stop "$PRIMARY"
CREATED_NAMES+=("$PUBLIC_COPY")
run "$SANDBOX_BIN" copy "$PRIMARY" "$PUBLIC_COPY" --public
PUBLIC_PORT="$(env_value "$PUBLIC_COPY" PORT_BASE)"
[ "$PUBLIC_PORT" != "$PORT_BASE" ] || fail "copy reused the source port block"
assert_eq "tcp:0.0.0.0:$PUBLIC_PORT" \
  "$(lxc config device get "$PUBLIC_COPY" ai-sandbox-ssh listen)" "public SSH bind"
assert_eq "tcp:0.0.0.0:$((PUBLIC_PORT + 1))" \
  "$(lxc config device get "$PUBLIC_COPY" ai-sandbox-novnc listen)" "public noVNC bind"
assert_ssh "$PUBLIC_COPY"
HOST_IPV4="$(ip -4 -o addr show scope global | awk '$2 != "tailscale0" { split($4, a, "/"); print a[1]; exit }')"
[ -n "$HOST_IPV4" ] || fail "no non-loopback host IPv4 address is available"
assert_http "http://$HOST_IPV4:$((PUBLIC_PORT + 1))/"
[ "$(ssh-keygen -lf "$HOME/.ai-sandbox/ssh/${PRIMARY}_ed25519.pub" -E sha256 | awk '{print $2}')" != \
  "$(ssh-keygen -lf "$HOME/.ai-sandbox/ssh/${PUBLIC_COPY}_ed25519.pub" -E sha256 | awk '{print $2}')" ] ||
  fail "copy reused the source access key"

log "testing export and import"
run "$SANDBOX_BIN" export "$PRIMARY" "$ARCHIVE"
[ -s "$ARCHIVE" ] || fail "export archive is missing or empty"
CREATED_NAMES+=("$IMPORTED")
run "$SANDBOX_BIN" create "$IMPORTED" --from "$ARCHIVE"
assert_ssh "$IMPORTED"
IMPORT_PORT="$(env_value "$IMPORTED" PORT_BASE)"
[ "$IMPORT_PORT" != "$PORT_BASE" ] || fail "import reused the source port block"
[ "$(ssh-keygen -lf "$HOME/.ai-sandbox/ssh/${PRIMARY}_ed25519.pub" -E sha256 | awk '{print $2}')" != \
  "$(ssh-keygen -lf "$HOME/.ai-sandbox/ssh/${IMPORTED}_ed25519.pub" -E sha256 | awk '{print $2}')" ] ||
  fail "import reused the source access key"

log "testing explicit destruction and state cleanup"
for name in "$IMPORTED" "$PUBLIC_COPY" "$PRIMARY"; do
  printf '%s\n' "$name" | "$SANDBOX_BIN" destroy "$name" >>"$LOG" 2>&1
  assert_destroyed "$name"
done

log 'PASS: every advertised command completed against real services'
