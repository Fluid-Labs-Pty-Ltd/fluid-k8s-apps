#!/usr/bin/env bash
#
# CI policy checks for fluid-k8s-apps.
#
#   bash ci/check.sh                                    every check
#   bash ci/check.sh prune                              manifests vs ci/app-policy.yaml
#   bash ci/check.sh render <app-dir> [renderer] [compare-legacy]
#
# The render check detects; it does not prevent. ArgoCD reads git directly, so on a
# push every cluster has already seen the commit before this runs. What it buys is a
# failed artifact publish, which keeps a subset render out of genesis. Blocking the
# change itself is branch protection's job, not this script's.

set -uo pipefail

ROOT=${FLUID_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
POLICY=$ROOT/ci/app-policy.yaml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rc=0
die()  { echo "error: $*" >&2; exit 2; }
fail() { echo "FAIL  $*" >&2; rc=1; }
pass() { echo "ok    $*"; }
need() { command -v "$1" >/dev/null || die "$1 not found on PATH"; }

# yq, kubectl and helm are native binaries on Windows and cannot read an MSYS path,
# which matters because this script is meant to be run locally before pushing, not
# only in CI.
native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# Wrapped rather than called directly because a yq that fails returns an empty string,
# and an empty string turns every check below into a green report over nothing.
y() { # expr file
    local out
    out=$(yq "$1" "$(native "$2")") || die "yq failed reading $2"
    printf '%s' "$out"
}

# Deliberately not using yq's `//`: it treats `false` as absent, so every app that
# needs prune: false — the only ones that matter here — would read as unclassified.
policy() { # app field -> value, or "null" when absent
    y ".applications[\"$1\"].$2" "$POLICY"
}

apps() {
    y '.applications | keys | .[]' "$POLICY"
}

# ---------------------------------------------------------------- prune + paths

check_prune() {
    need yq
    [[ -f $POLICY ]] || die "$POLICY not found"

    local seen=() f kind name path want got

    for f in "$ROOT"/.argo-apps/*.yaml; do
        kind=$(y '.kind // ""' "$f")
        [[ $kind == Application ]] || continue

        name=$(y '.metadata.name' "$f")
        seen+=("$name")

        if [[ $(y ".applications | has(\"$name\")" "$POLICY") != true ]]; then
            fail "$name: no entry in ci/app-policy.yaml"
            continue
        fi

        want=$(policy "$name" prune)
        if [[ $want != true && $want != false ]]; then
            fail "$name: ci/app-policy.yaml entry declares no prune value"
            continue
        fi

        got=$(y '.spec.syncPolicy.automated.prune' "$f")
        [[ $got == null ]] && got=unset
        if [[ $got == "$want" ]]; then
            pass "$name: prune=$got"
        else
            fail "$name: prune is $got, ci/app-policy.yaml requires $want"
        fi

        # The calico Application pointed at a directory moved in 2023 and nothing
        # noticed for two and a half years, because a dead source.path surfaces as a
        # ComparisonError inside a cluster and never in CI.
        path=$(y '.spec.source.path // ""' "$f")
        if [[ -z $path ]]; then
            fail "$name: no spec.source.path"
        elif [[ ! -d $ROOT/$path ]]; then
            fail "$name: spec.source.path '$path' does not exist in this repo"
        fi
    done

    # Every failure mode above skips the Application it was checking, so a run that
    # examined nothing would otherwise be indistinguishable from a clean one.
    [[ ${#seen[@]} -gt 0 ]] || die "no Application manifests found under .argo-apps/ — nothing was checked"

    # A classification with no Application is stale, and stale is how a file like
    # this stops being believed.
    local app
    while read -r app; do
        [[ -n $app ]] || continue
        if ! printf '%s\n' "${seen[@]}" | grep -qxF "$app"; then
            fail "$app: in ci/app-policy.yaml but has no .argo-apps manifest"
        fi
    done < <(apps)
}

# --------------------------------------------------------------------- render

render() { # dir renderer
    case $2 in
        kustomize) kubectl kustomize "$(native "$1")" ;;
        helm)      helm template "$(native "$1")" -f "$(native "$1/values.yaml")" ;;
        *)         die "unknown renderer '$2' for $1" ;;
    esac
}

# A rendered stream reduced to the identities ArgoCD prunes on. Comparing bytes would
# flag every image bump; comparing identities flags exactly the disappearances.
ids() {
    yq 'select(.kind != null)
        | [.apiVersion, .kind, (.metadata.namespace // "-"), (.metadata.name // "-")]
        | join("|")' - | sort -u
}

check_render_dir() { # app-dir renderer compare-legacy
    local dir=$1 renderer=$2 legacy=$3
    local ver name base out

    if [[ ! -d $dir/versions ]]; then
        echo "note  $dir has no versions/ — nothing to compare"
        return 0
    fi

    need yq
    case $renderer in helm) need helm ;; *) need kubectl ;; esac

    base=$WORK/$(echo "$dir" | tr '/\\:' '___')
    mkdir -p "$base"
    : > "$base/baseline"

    for ver in "$dir"/versions/*/; do
        [[ -d $ver ]] || continue
        name=$(basename "$ver")
        # A directory that will not render is a broken repo or broken tooling, not a
        # policy violation — exit distinctly so a render failure can never be mistaken
        # for a detected subset.
        render "$ver" "$renderer" | ids > "$base/$name.ids" \
            || die "$dir/versions/$name does not render"
        cat "$base/$name.ids" >> "$base/baseline"
    done

    # While the pre-versions directory still exists it is the set every cluster is
    # actually running, so it belongs in the baseline. Once it is deleted the siblings
    # carry the comparison on their own — which is why this cannot be a check against
    # the legacy path alone.
    if [[ $legacy == true && -f $dir/kustomization.yaml ]]; then
        # Same reasoning as above, and it matters more here: a legacy render that failed
        # quietly would shrink the baseline and turn a real subset into a pass.
        render "$dir" "$renderer" | ids >> "$base/baseline" \
            || die "$dir does not render"
    fi

    sort -u "$base/baseline" -o "$base/baseline"

    for ver in "$dir"/versions/*/; do
        [[ -d $ver ]] || continue
        name=$(basename "$ver")

        if [[ -f $ver/.allowed-removals ]]; then
            grep -vE '^[[:space:]]*(#|$)' "$ver/.allowed-removals" | sort -u > "$base/$name.allowed"
        else
            : > "$base/$name.allowed"
        fi

        out=$(comm -23 "$base/baseline" "$base/$name.ids" | comm -23 - "$base/$name.allowed")
        if [[ -z $out ]]; then
            pass "$dir/versions/$name"
        else
            fail "$dir/versions/$name renders a subset. A cluster moving to it has these pruned:"
            while read -r line; do
                [[ -n $line ]] && echo "          $line" >&2
            done <<< "$out"
            echo "        Declare them in versions/$name/.allowed-removals if the removal is" >&2
            echo "        intended and the orphan review is done." >&2
        fi
    done
}

check_render_all() {
    need yq
    local app path renderer legacy found=0

    while read -r app; do
        [[ -n $app ]] || continue
        path=$(policy "$app" path)
        [[ $path != null && -d $ROOT/$path/versions ]] || continue
        found=1

        renderer=$(policy "$app" renderer)
        [[ $renderer == null ]] && renderer=kustomize

        # Comparing against the legacy path is the default; only an app that has said
        # so explicitly opts out.
        legacy=$(policy "$app" compareLegacy)
        [[ $legacy == false ]] || legacy=true

        check_render_dir "$ROOT/$path" "$renderer" "$legacy"
    done < <(apps)

    # Said out loud, because a check that has never compared anything reports the same
    # green as one that has.
    [[ $found -eq 1 ]] || echo "note  no app has a versions/ directory yet — render check compared nothing"
}

# ----------------------------------------------------------------------- main

case ${1:-all} in
    all)
        check_prune
        check_render_all
        ;;
    prune)
        check_prune
        ;;
    render)
        [[ $# -ge 2 ]] || die "usage: check.sh render <app-dir> [renderer] [compare-legacy]"
        check_render_dir "$2" "${3:-kustomize}" "${4:-true}"
        ;;
    *)
        die "unknown check '$1'"
        ;;
esac

exit $rc
