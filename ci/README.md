# CI policy checks

Run everything locally before pushing:

```sh
bash ci/tests/run.sh    # proves the checks can actually fail
bash ci/check.sh        # the checks themselves
```

Needs `kubectl`, `yq`, and `helm` for helm-rendered apps. Works from Git Bash on
Windows.

`ci/tests/run.sh` covers three groups: the checked-in render fixtures, which pin the
identity format byte for byte against a `.allowed-removals` file; whole-repo cases built
at run time under `FLUID_REPO_ROOT`, which pin behaviour where the precondition is the
point of the case; and the helm path, via a stub `helm` in `ci/tests/bin` so the
arguments and the legacy entry file are testable without a network or a real chart.

Exit `0` clean, `1` a policy violation, `2` broken tooling or a repo the checks could
not read — a directory that will not render, a manifest yq cannot parse, a missing
binary. The last two are separate on purpose: a check that never ran must not be
reportable as a check that found nothing. A `2` means part of the sweep was skipped,
so it outranks a `1` even when both happened.

## `app-policy.yaml`

Classifies every Application in `.argo-apps/`. One file so the answer is stated once:
CI asserts the manifests against it, and the fluid-cloud version registry seeds from
the same list, without either side needing the other's access.

`check.sh` asserts:

- **Every entry's schema, on every run.** Field values are checked against their
  allowed sets and unknown keys are rejected, because a misspelled key reads as absent
  — `compareLagacy: false` is `compareLegacy: true`. This runs unconditionally: gating
  it behind "the app has a `versions/` directory" left the whole schema unchecked,
  since no app has one yet.
- **`prune` matches the classification**, in both directions. An Application with no
  entry fails, and an entry with no Application fails — a stale classification is how
  a file like this stops being believed.
- **`spec.source.path` exists in the repo.** A dead path only ever surfaces as a
  ComparisonError inside a cluster, so nothing catches it here otherwise. The calico
  Application pointed at a directory moved in early 2023 and went unnoticed for two
  and a half years.
- **The policy `path` equals that `spec.source.path`.** The render check is keyed off
  the policy value, so a stale one fails nothing — it silently stops checking that
  app. Renaming a directory and updating only the Application manifest is enough to
  do it.
- **No versioned directory renders a subset.** Each `versions/<ver>/` must render at
  least the resources its siblings and the pre-versions path do, and must render at
  least one resource — `kubectl kustomize` exits 0 on a kustomization that resolves to
  nothing, so an empty version would otherwise report `ok`.

`renderer` is `kustomize` unless stated, and selects the file treated as the
pre-versions render: `kustomization.yaml` for kustomize, `Chart.yaml` for helm. Keyed
off `kustomization.yaml` alone, a helm app's legacy path was skipped and a version short
of it read as `ok`.

`compareLegacy` must be written as literally `true` or `false`. yq v4 follows YAML 1.2,
where `no`, `off` and `0` are plain strings, and one of those would quietly switch a
comparison back on for an app that had opted out.

The namespace the helm renderer needs is read from the Application's
`spec.destination.namespace`, which is what ArgoCD renders with. It is deliberately not
restated in the policy: it lands in the rendered identities, and a second copy is a
second thing to keep in step. For the same reason the helm render passes
`--include-crds` and the Application name as the release name — ArgoCD does both, and
without them the identities compared are not the ones it would prune on.

An entry marked `review: pending` records a classification nobody has decided yet. The
value there is what CI enforces today, not a settled position.

## Why a version may not render a subset

ArgoCD deletes what a source path stops rendering. A cluster moving from one version
directory to another that omits a resource has that resource deleted — for `kubevirt`
that is the operator and the CRs, and therefore every VM.

Since any cluster may move between any two versions, the safe rule is that all
versions of an app render the same resource set, and every deliberate exception is
written down.

## Declaring what a version does not render

`check.sh` names the version directory that is short of something and prints each
identity in exactly the form to paste into that version's `.allowed-removals`:

```
apiVersion|kind|namespace|name
```

Use `-` for the namespace when the resource is cluster-scoped or unset.

This fires in **two** directions, and the second one catches people out:

- **A new version removes a resource.** The new version fails. Declare it there.
- **A new version adds a resource.** The *older* versions fail, because each of them
  now renders less than its sibling does. Declare it in each older version.

The second is not a false positive. Version directories are not a timeline — a cluster
can move from the new version back to an older one, and when it does, the resource that
older version never rendered is exactly what gets pruned. Declaring it says that path
has been thought about.

Either way the entry describes the same thing: a resource that stays behind on a
cluster which lands on this version having previously run a sibling that had it. So the
orphan review below applies to both.

An entry that matches nothing anything renders fails too. It exempts no resource, so it
is not a hole — but the file is the record of a completed review, and an entry left
behind after the version it was written for is gone is the case where that record has
stopped being true. Same reasoning as the stale-classification check above.

## Orphan review

Turning `prune` off trades a loud deletion for a silent accumulation, so a resource a
new version stops rendering now **stays on every cluster already running it**, forever.
Before shipping a version change to any app with `prune: false`, work through what the
old version rendered and the new one does not:

1. **Validating and mutating webhooks first.** These fail closed. A webhook object that
   outlives its backing service blocks *every* API operation on its resource type,
   cluster-wide — a far worse outcome than the deletion prune was avoiding. If a
   webhook is being removed, it must be deleted by hand as part of the rollout, not
   left behind.
2. **CRDs.** Orphaned CRDs keep their stored objects alive and can block a later
   reinstall that defines the same names differently.
3. **Everything else** — Deployments, Services, RBAC. Usually harmless, but a
   controller still running from an old version can fight the new one.

Record the outcome in `.allowed-removals` next to the version that drops them, so the
review is visible in the same diff as the change it justifies.
