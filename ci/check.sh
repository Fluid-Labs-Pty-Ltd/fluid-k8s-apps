#!/usr/bin/env bash
#
# CI policy checks for fluid-k8s-apps.
#
#   bash ci/check.sh                                    every check
#   bash ci/check.sh prune                              manifests vs ci/app-policy.yaml
#   bash ci/check.sh render <app-dir> [renderer] [compare-legacy] [namespace] [release]
#
# The render check detects; it does not prevent. ArgoCD reads git directly, so on a push
# every cluster has already seen the commit before this runs. What it buys is a failed
# artifact publish, which keeps a subset render out of genesis.
#
# Exit 0 clean, 1 a policy violation, 2 broken tooling or a repo the checks could not
# read. Kept apart so a check that never ran cannot be mistaken for one that passed.

set -uo pipefail

ROOT=${FLUID_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
POLICY=$ROOT/ci/app-policy.yaml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RENDERERS="kustomize helm"
RISKS="data-loss outage outage-recovery degraded low"
POLICY_KEYS="path renderer compareLegacy risk prune review rationale note"

rc=0
broken=0
die()    { echo "error: $*" >&2; exit 2; }
fail()   { echo "FAIL  $*" >&2; rc=1; }
pass()   { echo "ok    $*"; }
need()   { command -v "$1" >/dev/null || die "$1 not found on PATH"; }
# Unlike die(), lets the sweep finish: one unreadable app used to take every app after
# it down with no output at all.
broke()  { echo "error: $*" >&2; broken=1; }
detail() { local l; while read -r l; do [[ -n $l ]] && echo "          $l" >&2; done <<< "$1"; }
has()    { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# Native binaries on Windows cannot read an MSYS path, and this is meant to run locally
# before pushing, not only in CI.
native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# ------------------------------------------------------------------ policy file

POLICY_LOADED=0

load_policy() {
    [[ $POLICY_LOADED -eq 1 ]] && return 0
    need yq
    [[ -f $POLICY ]] || die "$POLICY not found"

    # Into files, not $( ): a yq failure inside command substitution kills only the
    # subshell, and the empty string the caller then gets reads as a clean pass.
    #
    # keys comes first in the array on purpose — yq materialises a path as it traverses
    # it, so reading .value.renderer before keys would report renderer as present on
    # every app.
    yq '.applications | to_entries | .[]
        | [.key, (.value | keys | join(",")), .value.path, .value.renderer,
           .value.compareLegacy, .value.prune, .value.risk]
        | join("|")' "$(native "$POLICY")" > "$WORK/policy" \
        || die "yq failed reading $POLICY"
    [[ -s $WORK/policy ]] || die "$POLICY declares no applications"

    cut -d'|' -f1 "$WORK/policy" > "$WORK/apps"
    POLICY_LOADED=1
    validate_policy
}

apps() { cat "$WORK/apps"; }

# Absent reads as empty, including for prune: yq's `//` would fold false into absent,
# so every prune: false app — the only ones that matter — would read as unclassified.
policy() { # app field
    local n
    case $2 in
        path) n=3 ;; renderer) n=4 ;; compareLegacy) n=5 ;; prune) n=6 ;; risk) n=7 ;;
        *) die "policy(): unknown field '$2'" ;;
    esac
    awk -F'|' -v a="$1" -v n="$n" '$1==a {print $n; exit}' "$WORK/policy"
}

# Every entry, unconditionally. Reading these only inside the render loop meant an app
# with no versions/ directory — which is all of them today — had its renderer,
# compareLegacy and key spelling validated by nothing.
validate_policy() {
    local app keys path renderer legacy prune risk k
    # Not tab-delimited: tab is IFS whitespace, so read collapses runs of it and an
    # absent field silently shifts every field after it.
    while IFS='|' read -r app keys path renderer legacy prune risk; do
        [[ -n $app ]] || continue

        [[ -n $path ]] || fail "$app: ci/app-policy.yaml declares no path"

        [[ -z $renderer ]] || has "$RENDERERS" "$renderer" \
            || fail "$app: ci/app-policy.yaml renderer '$renderer' is not one of: $RENDERERS"

        case $legacy in
            ''|true|false) ;;
            *) fail "$app: ci/app-policy.yaml compareLegacy must be true or false, got '$legacy'" ;;
        esac

        case $prune in
            true|false) ;;
            *) fail "$app: ci/app-policy.yaml declares no prune value" ;;
        esac

        has "$RISKS" "$risk" \
            || fail "$app: ci/app-policy.yaml risk '$risk' is not one of: $RISKS"

        # A misspelled key reads as absent, which is how compareLegacy: false silently
        # becomes compareLegacy: true.
        for k in ${keys//,/ }; do
            has "$POLICY_KEYS" "$k" || fail "$app: ci/app-policy.yaml has unknown key '$k'"
        done
    done < "$WORK/policy"
}

# ---------------------------------------------------------------- prune + paths

check_prune() {
    load_policy

    local seen=() m=() f base kind name got path destns want ppath
    : > "$WORK/index"

    for f in "$ROOT"/.argo-apps/*.yaml; do
        base=$(basename "$f")

        # Outside $( ) for the same reason as load_policy: read through command
        # substitution, a parse failure returns an empty kind that reads as "not an
        # Application" and the file is skipped as a pass.
        if ! yq '[.kind // "", .metadata.name // "", .spec.syncPolicy.automated.prune,
                  .spec.source.path // "", .spec.destination.namespace // ""] | .[]' \
            "$(native "$f")" > "$WORK/manifest" 2>"$WORK/manifest.err"; then
            broke "$base: yq could not read it — $(head -n1 "$WORK/manifest.err")"
            continue
        fi

        mapfile -t m < "$WORK/manifest"
        kind=${m[0]-}; name=${m[1]-}; got=${m[2]-}; path=${m[3]-}; destns=${m[4]-}

        [[ $kind == Application ]] || continue
        if [[ -z $name ]]; then
            broke "$base: Application has no metadata.name"
            continue
        fi
        seen+=("$name")
        printf '%s\t%s\t%s\n' "$name" "$path" "$destns" >> "$WORK/index"

        # The calico Application pointed at a directory moved in 2023 and nothing
        # noticed for two and a half years: a dead source.path surfaces as a
        # ComparisonError inside a cluster and never in CI. Asserted before the policy
        # lookup so a missing entry cannot skip it.
        if [[ -z $path ]]; then
            fail "$name: no spec.source.path"
        elif [[ ! -d $ROOT/$path ]]; then
            fail "$name: spec.source.path '$path' does not exist in this repo"
        fi

        if ! grep -qxF "$name" "$WORK/apps"; then
            fail "$name: no entry in ci/app-policy.yaml"
            continue
        fi

        want=$(policy "$name" prune)
        if [[ $want == true || $want == false ]]; then
            [[ $got == null ]] && got=unset
            if [[ $got == "$want" ]]; then
                pass "$name: prune=$got"
            else
                fail "$name: prune is $got, ci/app-policy.yaml requires $want"
            fi
        fi

        # The render check is keyed off the policy path, not the manifest's, so a stale
        # value fails nothing — it stops checking that app, silently once any app has a
        # versions/ directory.
        ppath=$(policy "$name" path)
        if [[ -n $ppath && $ppath != "$path" ]]; then
            fail "$name: ci/app-policy.yaml path '$ppath' does not match spec.source.path '$path'"
        fi
    done

    # Every failure mode above skips the Application it was checking, so a run that
    # examined nothing would otherwise look like a clean one.
    [[ ${#seen[@]} -gt 0 ]] || die "no Application manifests found under .argo-apps/ — nothing was checked"

    local app
    while read -r app; do
        [[ -n $app ]] || continue
        if ! printf '%s\n' "${seen[@]}" | grep -qxF "$app"; then
            fail "$app: in ci/app-policy.yaml but has no .argo-apps manifest"
        fi
    done < <(apps)
}

# --------------------------------------------------------------------- render

render() { # dir renderer namespace release
    local dir=$1 renderer=$2 ns=${3:-} release=${4:-release-name}
    local args=()

    case $renderer in
        kustomize)
            kubectl kustomize "$(native "$dir")"
            ;;
        helm)
            # Chart.yaml declares a remote dependency and charts/ is untracked, so
            # helm template on a fresh checkout fails without this. Production's
            # pipeline already does it.
            helm dependency build "$(native "$dir")" >/dev/null || return 1
            [[ -f $dir/values.yaml ]] && args+=(-f "$(native "$dir/values.yaml")")
            [[ -n $ns ]] && args+=(-n "$ns")
            # ArgoCD includes CRDs unless skipCrds is set, and uses the Application name
            # as the release name. Without both, the identities compared here are not
            # the ones ArgoCD would prune on.
            helm template "$release" "$(native "$dir")" --include-crds ${args[@]+"${args[@]}"}
            ;;
        *)
            echo "error: unknown renderer '$renderer' for $dir" >&2
            return 1
            ;;
    esac
}

ids() {
    # sed, not grep: a stream yq selects nothing out of still yields one blank line, and
    # grep -v would exit 1 on the all-blank case and trip pipefail. The blank counts as
    # an identity, so an empty render would look non-empty.
    yq 'select(.kind != null)
        | [.apiVersion, .kind, (.metadata.namespace // "-"), (.metadata.name // "-")]
        | join("|")' - | sed '/^[[:space:]]*$/d' | sort -u
}

check_render_dir() { # app-dir renderer compare-legacy [namespace] [release]
    local dir=$1 renderer=$2 legacy=$3 ns=${4:-} release=${5:-}
    local ver name base out unmatched entry nver=0 unrendered=0

    [[ -n $release ]] || release=$(basename "$dir")

    case $legacy in
        true|false) ;;
        *) die "compare-legacy must be true or false, got '$legacy'" ;;
    esac

    if [[ ! -d $dir/versions ]]; then
        echo "note  $dir has no versions/ — nothing to compare"
        return 0
    fi

    need yq
    case $renderer in
        helm)      need helm;    entry=Chart.yaml ;;
        kustomize) need kubectl; entry=kustomization.yaml ;;
        *)         die "unknown renderer '$renderer' for $dir" ;;
    esac

    base=$WORK/$(echo "$dir" | tr '/\\:' '___')
    mkdir -p "$base"
    : > "$base/baseline"

    # The release name comes from the app rather than each directory, so the legacy
    # render and every version render agree on it. Derived per directory, a chart using
    # .Release.Name would report differences that are an artefact of the path.
    for ver in "$dir"/versions/*/; do
        [[ -d $ver ]] || continue
        nver=$((nver+1))
        name=$(basename "$ver")

        if ! render "$ver" "$renderer" "$ns" "$release" | ids > "$base/$name.ids"; then
            broke "$dir/versions/$name does not render"
            unrendered=1
            continue
        fi

        # kubectl kustomize exits 0 on a kustomization resolving to nothing, so without
        # this an empty version reports ok whenever nothing else contributes a baseline.
        [[ -s $base/$name.ids ]] || fail "$dir/versions/$name renders no resources"

        cat "$base/$name.ids" >> "$base/baseline"
    done

    # An empty versions/ passes the -d test above and matches no glob, so this used to
    # produce no output and exit 0 while still counting as render-checked.
    if [[ $nver -eq 0 ]]; then
        fail "$dir/versions/ exists but contains no version directories"
        return 0
    fi

    # While the pre-versions directory exists it is the set every cluster is actually
    # running, so it belongs in the baseline. Once deleted, the siblings carry the
    # comparison alone — which is why this cannot be a check against legacy alone.
    if [[ $legacy == true && -f $dir/$entry ]]; then
        if ! render "$dir" "$renderer" "$ns" "$release" | ids >> "$base/baseline"; then
            broke "$dir does not render"
            unrendered=1
        fi
    fi

    # A missing render shrinks the baseline, so every comparison against it would report
    # a pass it has not earned. Stop at this directory; the caller moves on.
    [[ $unrendered -eq 0 ]] || return 0

    sort -u "$base/baseline" -o "$base/baseline"

    for ver in "$dir"/versions/*/; do
        [[ -d $ver ]] || continue
        name=$(basename "$ver")
        [[ -s $base/$name.ids ]] || continue

        if [[ -f $ver/.allowed-removals ]]; then
            # tr first: grep -v drops whole lines, it does not strip characters from the
            # ones it keeps, so on a core.autocrlf=true clone every declared identity
            # kept a \r and matched nothing.
            tr -d '\r' < "$ver/.allowed-removals" \
                | grep -vE '^[[:space:]]*(#|$)' | sort -u > "$base/$name.allowed"
        else
            : > "$base/$name.allowed"
        fi

        out=$(comm -23 "$base/baseline" "$base/$name.ids" | comm -23 - "$base/$name.allowed")
        if [[ -z $out ]]; then
            pass "$dir/versions/$name"
        else
            fail "$dir/versions/$name renders a subset. A cluster moving to it has these pruned:"
            detail "$out"
            echo "        Declare them in versions/$name/.allowed-removals if the removal is" >&2
            echo "        intended and the orphan review is done." >&2
        fi

        # The file records a completed orphan review; an entry matching nothing is the
        # case where that record has stopped being true.
        unmatched=$(comm -13 "$base/baseline" "$base/$name.allowed")
        if [[ -n $unmatched ]]; then
            fail "$dir/versions/$name: .allowed-removals declares identities nothing renders:"
            detail "$unmatched"
        fi
    done
}

check_render_all() {
    load_policy
    local app line path renderer legacy ns found=0

    while read -r app; do
        [[ -n $app ]] || continue

        path=$(policy "$app" path)
        [[ -n $path && -d $ROOT/$path/versions ]] || continue

        renderer=$(policy "$app" renderer)
        [[ -n $renderer ]] || renderer=kustomize
        has "$RENDERERS" "$renderer" || continue

        legacy=$(policy "$app" compareLegacy)
        case $legacy in
            '')         legacy=true ;;
            true|false) ;;
            *)          continue ;;
        esac

        # Namespace comes from the Application, not the policy: ArgoCD renders with
        # spec.destination.namespace, and a copy in the policy is a second thing to keep
        # in step with it.
        line=$(awk -F'\t' -v a="$app" '$1==a {print; exit}' "$WORK/index" 2>/dev/null)
        [[ -n $line ]] || continue
        ns=$(cut -f3 <<< "$line")

        found=1
        check_render_dir "$ROOT/$path" "$renderer" "$legacy" "$ns" "$app"
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
        [[ $# -ge 2 ]] || die "usage: check.sh render <app-dir> [renderer] [compare-legacy] [namespace] [release]"
        check_render_dir "$2" "${3:-kustomize}" "${4:-true}" "${5:-}" "${6:-}"
        ;;
    *)
        die "unknown check '$1'"
        ;;
esac

# Broken tooling outranks a policy failure: part of the sweep did not run, so exit 1
# would understate what is known.
[[ $broken -eq 0 ]] || exit 2
exit $rc
