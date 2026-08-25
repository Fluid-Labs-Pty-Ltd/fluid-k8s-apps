#!/usr/bin/env bash
#
# Fixture tests for ci/check.sh's render check.
#
# These exist because the check is inert until an app grows a versions/ directory.
# Without them it would report green on every build while never having compared
# anything, which is indistinguishable from working.
#
#   bash ci/tests/run.sh

set -uo pipefail

CI=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES=$CI/tests/fixtures
rc=0

expect() { # expected-exit fixture description
    local out status
    out=$(bash "$CI/check.sh" render "$FIXTURES/$2" kustomize true 2>&1)
    status=$?
    if [[ $status -eq $1 ]]; then
        echo "ok    $3"
    else
        echo "FAIL  $3 — expected exit $1, got $status"
        sed 's/^/      /' <<< "$out"
        rc=1
    fi
}

expect 0 identical         "versions rendering the same set pass"
expect 1 subset            "a version dropping a resource fails"
expect 1 subset-vs-legacy  "a version dropping a resource the legacy path has fails"
expect 1 forward-addition  "a version whose sibling adds a resource fails, with no legacy path"
expect 0 declared-removal  "a removal declared in .allowed-removals passes"

exit $rc
