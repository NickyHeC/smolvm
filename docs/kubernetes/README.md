# Kubernetes: a pod as its own microVM

smolvm ships a **containerd shim v2** (`io.containerd.smolvm.v2`), so Kubernetes can run a pod as
its own microVM through a `RuntimeClass`, the same integration point Kata uses. The Linux release
carries the shim and the manifests; there is nothing to build.

There is no `SKILL.md` for this topic yet. The procedure an agent would follow is held until the
open questions below are settled.

## Install, on each node that should run microVM pods

The node needs KVM. The paths below are the ones in the repository; earlier documentation named a
`kubernetes/` directory that does not exist.

```bash
# 1. install the shim and runtime artifacts, then apply the containerd config it prints
sudo ./scripts/install-k8s-runtime.sh --runtime-dir /opt/smolvm
sudo systemctl restart containerd

# 2. label the node so the RuntimeClass schedules to it
kubectl label node <node> smolvm-runtime=true

# 3. register the class and run a pod
kubectl apply -f deploy/kubernetes/runtimeclass.yaml
kubectl apply -f deploy/kubernetes/example-pod.yaml
kubectl logs smolvm-hello    # prints the guest's own kernel, so it is a real VM
```

Any pod opts in with `runtimeClassName: smolvm`.

## What works, and the configuration it needs

The stock shim runs a pod when containerd is **older than 2.3** and the pod carries
`container.apparmor.security.beta.kubernetes.io/<container>: unconfined`. On containerd 2.3 and
later a separate defect blocks it before anything else. The shipped example pod does not carry that
annotation, so it fails on any AppArmor-enforcing node: that is the configuration to teach, not the
one the older documentation implies.

`install-k8s-runtime.sh` needs `--runtime-dir`; without it the documented command fails as written.

## Conformance

`critest` (cri-tools v1.31.1) on the reference node: 82 passed, 7 failed, 24 skipped of 113, at or
above the runc baseline of 79 on the same host. The seven failures are the boundary of any VM-based
runtime and fail for Kata, Firecracker and gVisor too: port forwarding dials loopback in the pod
network namespace while the workload listens inside the VM; `HostNetwork` and `HostIpc` cannot be
shared by a machine with its own kernel; and bidirectional mount propagation does not cross the VM
boundary.

`deploy/` holds the manifests and the installer, and `deploy/README.md` has the full conformance
table and the node requirements.
