# CI policy checks

Run everything locally before pushing:

```sh
bash ci/tests/run.sh    # proves the render check can actually fail
bash ci/check.sh        # the checks themselves
```

Needs `kubectl`, `yq`, and `helm` for helm-rendered apps. Works from Git Bash on
Windows.

## `app-policy.yaml`

Classifies every Application in `.argo-apps/`. One file so the answer is stated once:
CI asserts the manifests against it, and the fluid-cloud version registry seeds from
the same list, without either side needing the other's access.

`check.sh` asserts three things:

- **`prune` matches the classification**, in both directions. An Application with no
  entry fails, and an entry with no Application fails — a stale classification is how
  a file like this stops being believed.
- **`spec.source.path` exists in the repo.** A dead path only ever surfaces as a
  ComparisonError inside a cluster, so nothing catches it here otherwise. The calico
  Application pointed at a directory moved in early 2023 and went unnoticed for two
  and a half years.
- **No versioned directory renders a subset.** Each `versions/<ver>/` must render at
  least the resources its siblings and the pre-versions path do.

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
