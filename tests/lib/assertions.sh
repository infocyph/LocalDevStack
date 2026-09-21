#!/usr/bin/env bash

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

assert_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "expected file: $file"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

assert_exit() {
  local expected="$1"
  shift
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  [[ "$code" -eq "$expected" ]] || fail "expected exit $expected, got $code: $*"
}
