#!/usr/bin/env bash
# Safe tests: syntax checks, ShellCheck (if installed) and unit tests of the
# pure helper functions. Needs no root and changes nothing on the system.
#
#   ./setup/tests/run_tests.sh
set -Eeuo pipefail

SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/logging.sh
source "$SETUP_ROOT/lib/logging.sh"
# shellcheck source=../lib/validate.sh
source "$SETUP_ROOT/lib/validate.sh"

PASSED=0
FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

ok()   { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL: %s\n' "$*" >&2; }

assert_true()  { if "$@"; then ok; else fail "expected true: $*"; fi; }
assert_false() { if "$@"; then fail "expected false: $*"; else ok; fi; }
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then ok; else fail "$label: expected [$expected] got [$actual]"; fi
}

test_syntax() {
  local f
  while IFS= read -r -d '' f; do
    if bash -n "$f"; then ok; else fail "bash -n $f"; fi
  done < <(find "$SETUP_ROOT" -name '*.sh' -print0)
}

test_shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed; skipping (sudo apt install shellcheck)"
    return 0
  fi
  local files=()
  mapfile -d '' files < <(find "$SETUP_ROOT" -name '*.sh' -print0)
  if (cd "$SETUP_ROOT" && shellcheck -x -S warning "${files[@]}"); then ok; else fail "shellcheck reported problems"; fi
}

test_validators() {
  assert_true is_valid_memory 512m;   assert_true is_valid_memory 2g
  assert_false is_valid_memory 0g;    assert_false is_valid_memory 2gb; assert_false is_valid_memory ""
  assert_true is_valid_cpus 2;        assert_true is_valid_cpus 0.5
  assert_false is_valid_cpus 0;       assert_false is_valid_cpus 0.0;   assert_false is_valid_cpus -1
  assert_true is_positive_int 256;    assert_false is_positive_int 0;   assert_false is_positive_int 1.5
  assert_true is_valid_agent_id agent-001; assert_false is_valid_agent_id Agent; assert_false is_valid_agent_id ../x
  assert_true is_valid_env_name ANTHROPIC_API_KEY; assert_false is_valid_env_name 1BAD; assert_false is_valid_env_name 'A-B'
  assert_true is_valid_network_mode offline; assert_false is_valid_network_mode host
  assert_true is_valid_domain_pattern api.openai.com; assert_true is_valid_domain_pattern .github.com
  assert_false is_valid_domain_pattern 'evil.com/path'; assert_false is_valid_domain_pattern '*'
  assert_false is_valid_domain_pattern 'localhost'; assert_false is_valid_domain_pattern '10.0.0.1'
  assert_true is_bool true; assert_false is_bool yes
}

test_modes() {
  assert_true mode_exceeds 644 640;  assert_false mode_exceeds 640 640
  assert_true mode_exceeds 666 644;  assert_false mode_exceeds 600 644
  assert_true mode_exceeds 4755 755
  assert_eq 640 "$(mode_clamp 644 640)" "mode_clamp 644 640"
  assert_eq 600 "$(mode_clamp 666 600)" "mode_clamp 666 600"
}

denied() { mount_denial_reason "$@" >/dev/null; }

test_mount_policy() {
  local home=/home/alice
  assert_true denied / "$home"
  assert_true denied "$home" "$home"
  assert_true denied /home "$home"
  assert_true denied "$home/.ssh" "$home"
  assert_true denied "$home/.config/gh" "$home"
  assert_true denied /var/run/docker.sock "$home"
  assert_true denied /etc "$home"
  assert_true denied "$home/src" "$home" "$home/src/setup-repo"
  assert_false denied "$home/agent-workspaces/agent-001" "$home"
  assert_false denied "$home/projects/my-agent" "$home"
  assert_false denied "$home/.sshfoo" "$home"
}

test_loopback() {
  assert_true is_loopback_address 127.0.0.1:631
  assert_true is_loopback_address 127.0.0.53%lo:53
  assert_true is_loopback_address '[::1]:5432'
  assert_true is_loopback_address '[::ffff:127.0.0.1]:63342'
  assert_false is_loopback_address 0.0.0.0:22
  assert_false is_loopback_address '[::]:22'
  assert_false is_loopback_address '*:5353'
  assert_false is_loopback_address 192.168.1.5:8000
}

test_managed_block() {
  local f="$TMP/profile" out
  printf 'line1\nline2\n' >"$f"
  out="$(printf 'export A=1' | render_managed_block "$f" test)"
  printf '%s\n' "$out" >"$f"
  assert_eq 5 "$(wc -l <"$f")" "block appended once"
  out="$(printf 'export A=2' | render_managed_block "$f" test)"
  printf '%s\n' "$out" >"$f"
  assert_eq 5 "$(wc -l <"$f")" "block replaced, not duplicated"
  assert_eq 1 "$(grep -c 'export A=2' "$f")" "new block content present"
  assert_eq 0 "$(grep -c 'export A=1' "$f" || true)" "old block content removed"
  out="$(printf 'x\\ny' | render_managed_block /dev/null esc)"
  assert_true grep -qF 'x\ny' <<<"$out"
}

test_kv() {
  local f="$TMP/ufw"
  printf 'IPV6=no\nDEFAULT_INPUT_POLICY="DROP"\n# IPV6=comment\n' >"$f"
  assert_eq 'IPV6=yes' "$(render_kv "$f" IPV6 yes | head -n1)" "render_kv replaces"
  assert_eq 3 "$(render_kv "$f" IPV6 yes | wc -l)" "render_kv keeps other lines"
  assert_eq 'NEW=1' "$(render_kv "$f" NEW 1 | tail -n1)" "render_kv appends"
}

test_sysctl_parse() {
  local out
  out="$(parse_sysctl_file "$SETUP_ROOT/hardening/files/60-ai-workstation-hardening.conf")"
  assert_true grep -qx 'kernel.kptr_restrict 1' <<<"$out"
  assert_false grep -q 'ip_forward' <<<"$out"
  assert_false grep -q '^#' <<<"$out"
}

test_redaction() {
  local out
  out="$(printf 'OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123 ok' | redact_secrets)"
  assert_false grep -q 'sk-abc' <<<"$out"
  out="$(printf 'token ghp_abcdefghijklmnopqrstuvwxyz0123456789' | redact_secrets)"
  assert_false grep -q 'ghp_abc' <<<"$out"
  out="$(printf 'postgres://user:hunter2@db:5432/x' | redact_secrets)"
  assert_false grep -q hunter2 <<<"$out"
  out="$(printf 'PasswordAuthentication no' | redact_secrets)"
  assert_eq 'PasswordAuthentication no' "$out" "non-secret text untouched"
}

test_json_escape() {
  assert_eq 'a\"b\\c\nd' "$(json_escape $'a"b\\c\nd')" "json_escape"
  if command -v python3 >/dev/null 2>&1; then
    local s
    s="{\"v\":\"$(json_escape $'quote" tab\t nl\n ctrl\x01')\"}"
    if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$s"; then ok; else fail "json_escape output is not valid JSON"; fi
  fi
}

test_allowlist() {
  local rc=0
  (
    # render_allowlist lives in agent.sh, which expects common.sh.
    # shellcheck source=../lib/common.sh
    source "$SETUP_ROOT/lib/common.sh"
    # shellcheck source=../lib/agent.sh
    source "$SETUP_ROOT/lib/agent.sh"
    local f="$TMP/allow"
    printf '# c\nAPI.Example.com  # comment\n\n.github.com\napi.example.com\n' >"$f"
    [[ "$(render_allowlist "$f" | wc -l)" == 2 ]] || exit 1
    render_allowlist "$SETUP_ROOT/agents/policies/restricted-allowlist.txt" >/dev/null || exit 2
    printf 'bad/entry\n' >"$f"
    if render_allowlist "$f" >/dev/null 2>&1; then exit 3; fi
  ) || rc=$?
  if ((rc == 0)); then ok; else fail "render_allowlist (exit $rc)"; fi
}

test_python_audit() {
  command -v python3 >/dev/null 2>&1 || return 0
  local log="$TMP/events.jsonl"
  # shellcheck disable=SC2031  # the subshell in test_allowlist re-sets the same value
  PYTHONDONTWRITEBYTECODE=1 AGENT_AUDIT_LOG="$log" AGENT_ID=t PYTHONPATH="$SETUP_ROOT/agents/tools" python3 - <<'EOF'
from agent_audit import log_event, redact
log_event("http", "GET", target="https://u:pw@example.com", headers={"Authorization": "Bearer x"},
          body="key sk-abcdefghijklmnopqrstuvwxyz")
assert redact({"api_key": "v"}) == {"api_key": "[REDACTED]"}
EOF
  if grep -q 'pw@\|Bearer x\|sk-abc' "$log"; then fail "agent_audit leaked a secret"; else ok; fi
}

main() {
  test_syntax
  test_shellcheck
  test_validators
  test_modes
  test_mount_policy
  test_loopback
  test_managed_block
  test_kv
  test_sysctl_parse
  test_redaction
  test_json_escape
  test_allowlist
  test_python_audit
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  ((FAILED == 0))
}

main "$@"
