#!/usr/bin/env bash
# Dispatcher tests: routing, help/version, unknown command, and the
# symlinked-invocation regression (mise shims / ~/.local/bin installs).
set -euo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null
  pwd -P
)"
BIN="$ROOT_DIR/bin/trunkyard"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/trunkyard-dispatcher.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
PASS_COUNT=0

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "ok $1"; }

# help exits 0 and shows the three subcommands without leaking code
out="$("$BIN" --help)"
[[ "$out" == *"trunkyard status"* && "$out" == *"trunkyard pull"* && "$out" == *"trunkyard new"* ]] || fail "help missing subcommands"
[[ "$out" != *"set -euo"* ]] || fail "help leaks script body"
pass help

# version (unstamped build reports dev)
[[ "$("$BIN" --version)" == trunkyard\ * ]] || fail "version output"
pass version

# unknown command: exit 2, error on stderr
if err="$("$BIN" bogus 2>&1 >/dev/null)"; then fail "bogus should fail"; else rc=$?; fi
[[ "$rc" -eq 2 && "$err" == *"unknown command"* ]] || fail "bogus rc=$rc err=$err"
pass unknown-command

# status routes to git-workspace.sh and reports with the trunkyard name
mkdir -p "$TEST_ROOT/ws/repo"
git -C "$TEST_ROOT/ws/repo" init -q -b main
out="$("$BIN" status "$TEST_ROOT/ws" 2>&1)" || true
[[ "$out" == *repo* ]] || fail "status did not discover repo: $out"
pass route-status

# new with no args: usage mentions 'trunkyard new', exit 2
if err="$("$BIN" new 2>&1 >/dev/null)"; then fail "bare new should fail"; else rc=$?; fi
[[ "$rc" -eq 2 && "$err" == *"trunkyard new"* ]] || fail "new usage rc=$rc err=$err"
pass new-usage-name

# symlinked invocation resolves libexec through the link (regression)
mkdir -p "$TEST_ROOT/fakebin"
ln -s "$BIN" "$TEST_ROOT/fakebin/trunkyard"
out="$("$TEST_ROOT/fakebin/trunkyard" status "$TEST_ROOT/ws" 2>&1)" || fail "symlinked status failed: $out"
[[ "$out" == *repo* ]] || fail "symlinked status wrong output: $out"
# relative symlink chain (rel -> abs -> real file)
ln -s "trunkyard" "$TEST_ROOT/fakebin/rel-trunkyard"
out="$("$TEST_ROOT/fakebin/rel-trunkyard" status "$TEST_ROOT/ws" 2>&1)" || fail "relative symlink chain failed: $out"
[[ "$out" == *repo* ]] || fail "relative symlink wrong output: $out"
pass symlink-invocation

echo "passed $PASS_COUNT dispatcher tests"
