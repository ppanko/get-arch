#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source ./get-arch
CHECK_MODE=0; VERBOSE=0
parse_args --check --verbose
assert_eq 1 "$CHECK_MODE" '--check'
assert_eq 1 "$VERBOSE" '--verbose'
set +e
output=$(parse_args --bogus 2>&1); status=$?
set -e
assert_eq 2 "$status" 'unknown option status'
assert_contains "$output" 'Unknown option' 'unknown option message'
