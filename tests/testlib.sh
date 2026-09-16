#!/usr/bin/env bash
set -u
assert_eq() {
  local expected=$1 actual=$2 message=${3:-}
  [[ "$expected" == "$actual" ]] || {
    printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$message" "$expected" "$actual" >&2
    return 1
  }
}
assert_contains() {
  local haystack=$1 needle=$2 message=${3:-}
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'FAIL: %s\nmissing: %q\n' "$message" "$needle" >&2
    return 1
  }
}
assert_file_contains() { grep -Fq -- "$2" "$1"; }
