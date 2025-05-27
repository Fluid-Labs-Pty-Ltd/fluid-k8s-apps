# Cilium Templated Installation

### Notes

Generated from Helm Chart with values file - we should refresh the default values file for Cilium

Make sure you have added the cilium repo to your helm.

```
helm repo add cilium https://helm.cilium.io
```

# Choose Desired Version

```
export cilium_version=1.12.19

```

#### Check Values Files Changes

Generate Default Values and check for changed options - vs the values file

```
helm show values cilium/cilium --version $cilium_version  | tee default-values-$cilium_version.yaml
```

### Generate Manifest

```
helm template cilium/cilium --version $cilium_version --values values-helm-direct.yaml --include-crds --namespace kube-system | tee cilium.yaml
```
