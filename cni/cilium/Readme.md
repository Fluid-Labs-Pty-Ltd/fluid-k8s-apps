# Cilium Helm installation

The build workflow renders this directory directly from `Chart.yaml` and `values.yaml`.
Do not check in a pre-rendered `cilium.yaml`, because it can drift from the chart used
by the build pipeline.

## Render locally

The dependency must be downloaded before rendering a fresh checkout:

```bash
helm dependency build
helm template . -f values.yaml -n kube-system
```

## Review a Cilium version update

Keep `version`, `appVersion`, and the Cilium dependency version in `Chart.yaml` aligned.
To inspect changes in the upstream defaults:

```bash
export cilium_version=1.15.17
helm repo add cilium https://helm.cilium.io
helm show values cilium/cilium --version "$cilium_version" \
  | tee "default-values-$cilium_version.yaml"
```

`values-helm-direct.yaml` contains the equivalent values for rendering the upstream
chart directly when comparing it with this wrapper chart:

```bash
helm template cilium/cilium --version "$cilium_version" \
  --values values-helm-direct.yaml --include-crds --namespace kube-system
```
