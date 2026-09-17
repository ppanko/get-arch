#!/usr/bin/env bash
set -euo pipefail
source tests/testlib.sh
source ./get-arch
CHECK_MODE=0; VERBOSE=0; INSTALL_MODE=0; USERNAME=''
parse_args --check --verbose
assert_eq 1 "$CHECK_MODE" '--check'
assert_eq 1 "$VERBOSE" '--verbose'

CHECK_MODE=0; VERBOSE=0; INSTALL_MODE=0; USERNAME=''
parse_args --install-mode --user pavel --check
assert_eq 1 "$INSTALL_MODE" '--install-mode'
assert_eq pavel "$USERNAME" '--user'
assert_eq 1 "$CHECK_MODE" 'install mode can be checked non-destructively'

CHECK_MODE=0; VERBOSE=0; INSTALL_MODE=0; USERNAME=''
set +e
output=$(parse_args --user pavel 2>&1); status=$?
set -e
assert_eq 2 "$status" '--user without install mode status'
assert_contains "$output" '--user requires --install-mode' '--user is mode-scoped'

CHECK_MODE=0; VERBOSE=0; INSTALL_MODE=0; USERNAME=''
set +e
output=$(parse_args --install-mode --user 2>&1); status=$?
set -e
assert_eq 2 "$status" 'missing --user value status'
assert_contains "$output" '--user requires a username' 'missing --user value message'

set +e
output=$(parse_args --bogus 2>&1); status=$?
set -e
assert_eq 2 "$status" 'unknown option status'
assert_contains "$output" 'Unknown option' 'unknown option message'
