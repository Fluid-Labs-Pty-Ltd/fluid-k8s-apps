#!/usr/bin/env bash
#
# Fixture tests for ci/check.sh.
#
# These exist because most of what check.sh asserts is inert until some condition holds
# — an app grows a versions/ directory, a policy entry goes stale, a manifest stops
# parsing. Without them the script reports green on every build while never having
# checked anything, which is indistinguishable from working.
#
#   bash ci/tests/run.sh

set -uo pipefail

CI=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES=$CI/tests/fixtures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

report() { # ok|fail description output
    if [[ $1 == ok ]]; then
        echo "ok    $2"
    else
        echo "FAIL  $2"
        sed 's/^/      /' <<< "$3"
        rc=1
    fi
}

# Asserting the exit code alone pins very little: a failure naming the wrong version
# directory, or a policy error raised for the wrong reason, keeps every test green. Each
# case therefore also states substrings the output has to carry.
check() { # want-exit description output status [expected-substring...]
    local want=$1 desc=$2 out=$3 status=$4; shift 4
    local pat
    if [[ $status -ne $want ]]; then
        report fail "$desc — expected exit $want, got $status" "$out"
        return
    fi
    for pat in "$@"; do
        if ! grep -qF -- "$pat" <<< "$out"; then
            report fail "$desc — output does not mention '$pat'" "$out"
            return
        fi
    done
    report ok "$desc" ""
}

# ------------------------------------------------- render fixtures (checked in)

# These stay on disk because they pin a byte contract: what ids() emits has to match
# what a .allowed-removals file declares, character for character.
render_case() { # want-exit fixture description [expected-substring...]
    local want=$1 fixture=$2 desc=$3; shift 3
    local out status
    out=$(bash "$CI/check.sh" render "$FIXTURES/$fixture" kustomize true 2>&1)
    status=$?
    check "$want" "$desc" "$out" "$status" "$@"
}

echo "-- render"

render_case 0 identical         "versions rendering the same set pass" \
    "ok    $FIXTURES/identical/versions/v1" \
    "ok    $FIXTURES/identical/versions/v2"

render_case 1 subset            "a version dropping a resource fails" \
    "ok    $FIXTURES/subset/versions/v1" \
    "FAIL  $FIXTURES/subset/versions/v2 renders a subset" \
    "v1|ConfigMap|-|beta"

render_case 1 subset-vs-legacy  "a version dropping a resource the legacy path has fails" \
    "FAIL  $FIXTURES/subset-vs-legacy/versions/v1 renders a subset" \
    "v1|ConfigMap|-|beta"

render_case 1 forward-addition  "a version whose sibling adds a resource fails, with no legacy path" \
    "FAIL  $FIXTURES/forward-addition/versions/v1 renders a subset" \
    "ok    $FIXTURES/forward-addition/versions/v2" \
    "v1|ConfigMap|-|beta"

render_case 0 declared-removal  "a removal declared in .allowed-removals passes" \
    "ok    $FIXTURES/declared-removal/versions/v1" \
    "ok    $FIXTURES/declared-removal/versions/v2"

render_case 1 stale-allowed     "an .allowed-removals entry matching nothing fails" \
    "FAIL  $FIXTURES/stale-allowed/versions/v2: .allowed-removals declares identities nothing renders" \
    "v1|ConfigMap|-|ghost"

render_case 1 empty-versions    "a versions/ directory holding no versions fails" \
    "FAIL  $FIXTURES/empty-versions/versions/ exists but contains no version directories"

render_case 1 empty-render      "a version rendering nothing fails" \
    "FAIL  $FIXTURES/empty-render/versions/v1 renders no resources"

# ------------------------------------------------------ whole-repo cases (built)

# Built here rather than checked in: these pin behaviour, not a byte format, and the
# precondition is the whole point of each case — an assertion that only fires once an
# app has a versions/ directory is how the policy schema went unchecked. Writing the
# repo next to the assertion keeps that visible.

repo() { # name  -> prints root, creates ci/app-policy.yaml dir and .argo-apps/
    local root=$TMP/$1
    mkdir -p "$root/ci" "$root/.argo-apps"
    printf '%s' "$root"
}

app_manifest() { # root name path [namespace] [prune]
    mkdir -p "$1/.argo-apps"
    cat > "$1/.argo-apps/$2.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $2
spec:
  destination:
    namespace: ${4:-kube-system}
  source:
    path: $3
  syncPolicy:
    automated:
      prune: ${5:-true}
      selfHeal: true
EOF
    mkdir -p "$1/$3"
}

repo_case() { # want-exit root description [expected-substring...]
    local want=$1 root=$2 desc=$3; shift 3
    local out status
    out=$(FLUID_REPO_ROOT=$root bash "$CI/check.sh" 2>&1)
    status=$?
    check "$want" "$desc" "$out" "$status" "$@"
}

echo "-- policy and manifests"

# The last key in the policy used to be dropped from both loops that read it, so the
# last app was exempt from the stale-classification check and from the render check.
R=$(repo last-app)
cat > "$R/ci/app-policy.yaml" <<'EOF'
version: 1
applications:
  aaa:
    path: aaa
    risk: low
    prune: true
    rationale: fixture
  zzz-last:
    path: zzz-last
    risk: low
    prune: true
    rationale: fixture
EOF
app_manifest "$R" aaa aaa
mkdir -p "$R/zzz-last"
repo_case 1 "$R" "the last policy entry is not exempt from the stale check" \
    "FAIL  zzz-last: in ci/app-policy.yaml but has no .argo-apps manifest"

R=$(repo path-mismatch)
cat > "$R/ci/app-policy.yaml" <<'EOF'
version: 1
applications:
  app:
    path: renamed
    risk: low
    prune: true
    rationale: fixture
EOF
app_manifest "$R" app actual
mkdir -p "$R/renamed"
repo_case 1 "$R" "a policy path that differs from spec.source.path fails" \
    "FAIL  app: ci/app-policy.yaml path 'renamed' does not match spec.source.path 'actual'"

# A manifest nobody can parse is a repo the checks could not read, not a policy
# violation — it has to reach exit 2, or a green-looking 1 hides an unchecked file.
R=$(repo malformed-manifest)
cat > "$R/ci/app-policy.yaml" <<'EOF'
version: 1
applications:
  app:
    path: app
    risk: low
    prune: true
    rationale: fixture
EOF
app_manifest "$R" app app
printf 'apiVersion: v1\nkind: Application\nmetadata:\n\tname: broken\n' > "$R/.argo-apps/broken.yaml"
repo_case 2 "$R" "a manifest yq cannot parse exits 2, not 1" \
    "error: broken.yaml: yq could not read it"

# No app in these has a versions/ directory — the state the real repo is in, and the
# state in which none of the schema was validated.
policy_repo() { # name < policy-body
    local root; root=$(repo "$1")
    cat > "$root/ci/app-policy.yaml"
    app_manifest "$root" app app
    printf '%s' "$root"
}

R=$(policy_repo bad-renderer <<'EOF'
version: 1
applications:
  app:
    path: app
    renderer: helmm
    risk: low
    prune: true
    rationale: fixture
EOF
)
repo_case 1 "$R" "an invalid renderer fails with no versions/ present" \
    "FAIL  app: ci/app-policy.yaml renderer 'helmm' is not one of"

R=$(policy_repo bad-compare-legacy <<'EOF'
version: 1
applications:
  app:
    path: app
    compareLegacy: no
    risk: low
    prune: true
    rationale: fixture
EOF
)
repo_case 1 "$R" "compareLegacy: no fails with no versions/ present" \
    "FAIL  app: ci/app-policy.yaml compareLegacy must be true or false, got 'no'"

R=$(policy_repo unknown-key <<'EOF'
version: 1
applications:
  app:
    path: app
    compareLagacy: false
    risk: low
    prune: true
    rationale: fixture
EOF
)
repo_case 1 "$R" "a misspelled policy key is rejected" \
    "FAIL  app: ci/app-policy.yaml has unknown key 'compareLagacy'"

R=$(policy_repo bad-risk <<'EOF'
version: 1
applications:
  app:
    path: app
    risk: catastrophic
    prune: true
    rationale: fixture
EOF
)
repo_case 1 "$R" "an unknown risk class is rejected" \
    "FAIL  app: ci/app-policy.yaml risk 'catastrophic' is not one of"

R=$(policy_repo no-prune <<'EOF'
version: 1
applications:
  app:
    path: app
    risk: low
    rationale: fixture
EOF
)
repo_case 1 "$R" "a policy entry with no prune value is rejected" \
    "FAIL  app: ci/app-policy.yaml declares no prune value"

# One unrenderable app used to end the sweep, leaving every app after it unchecked with
# nothing said about it.
R=$(repo sweep)
cat > "$R/ci/app-policy.yaml" <<'EOF'
version: 1
applications:
  aaa-broken:
    path: aaa-broken
    risk: low
    prune: true
    rationale: fixture
  zzz-after:
    path: zzz-after
    risk: low
    prune: true
    rationale: fixture
EOF
app_manifest "$R" aaa-broken aaa-broken
app_manifest "$R" zzz-after zzz-after
mkdir -p "$R/aaa-broken/versions/v1" "$R/zzz-after/versions/v1"
printf 'this: is: not: a: kustomization\n' > "$R/aaa-broken/versions/v1/kustomization.yaml"
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
    > "$R/zzz-after/versions/v1/kustomization.yaml"
repo_case 2 "$R" "an unrenderable app does not stop the apps after it being checked" \
    "error: $R/aaa-broken/versions/v1 does not render" \
    "FAIL  $R/zzz-after/versions/v1 renders no resources"

# ------------------------------------------------------------------ helm cases

# The stub avoids needing network or a real chart; what is under test is the arguments
# check.sh builds and which entry file it treats as the legacy path.
echo "-- helm"

# Copied and chmodded here rather than run from ci/tests/bin directly: this repo is
# developed with core.filemode=false, so git records the stub as 0644 and PATH lookup on
# Linux would skip it and find the real helm — passing locally, failing in CI.
STUB_BIN=$TMP/bin
mkdir -p "$STUB_BIN"
cp "$CI/tests/bin/helm" "$STUB_BIN/helm"
chmod +x "$STUB_BIN/helm"

helm_chart() { # dir resources... ; marks the dir as a chart the stub can render
    local dir=$1; shift
    mkdir -p "$dir"
    printf 'apiVersion: v2\nname: c\nversion: 1.0.0\n' > "$dir/Chart.yaml"
    printf '%s\n' "$*" > "$dir/.stub"
}

helm_case() { # want-exit dir description ns release [expected-substring...]
    local want=$1 dir=$2 desc=$3 ns=$4 release=$5; shift 5
    local out status
    out=$(PATH="$STUB_BIN:$PATH" HELM_LOG=$TMP/helm.log \
          bash "$CI/check.sh" render "$dir" helm true "$ns" "$release" 2>&1)
    status=$?
    check "$want" "$desc" "$out" "$status" "$@"
}

# Chart.yaml is the legacy entry file for a helm app. Keyed off kustomization.yaml, a
# helm app's pre-versions render was skipped and a subset against it read as ok.
D=$TMP/helm-legacy
helm_chart "$D" alpha beta
helm_chart "$D/versions/v1" alpha
: > "$TMP/helm.log"
helm_case 1 "$D" "a helm version short of its Chart.yaml legacy render fails" kube-system cilium \
    "FAIL  $D/versions/v1 renders a subset" \
    "v1|ConfigMap|kube-system|beta"

check 0 "helm dependency build runs before template" "$(cat "$TMP/helm.log")" 0 \
    "dependency build"
check 0 "helm render passes --include-crds, -n and the release name" "$(cat "$TMP/helm.log")" 0 \
    "template cilium" "--include-crds" "-n kube-system"

# CRDs are part of what ArgoCD applies, so a version that stops shipping one is a subset.
D=$TMP/helm-crds
helm_chart "$D/versions/v1" alpha
helm_chart "$D/versions/v2" alpha
printf 'widgets.example.com\n' > "$D/versions/v1/.stub-crds"
helm_case 1 "$D" "a version dropping a CRD fails, so --include-crds is in effect" kube-system app \
    "FAIL  $D/versions/v2 renders a subset" \
    "v1|ConfigMap|kube-system|widgets.example.com"

exit $rc
