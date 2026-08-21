# The Layer 0 contract

Layer 0 provisions a Kubernetes cluster. It publishes **exactly three facts** about
that cluster, and Layer 1 is written against those three facts and nothing else.

This file is **normative**. A new L0 implementation (EKS, GKE, bare metal, a managed
cluster someone hands you) is correct if and only if it emits these three outputs
with these names and these meanings. Nothing above L0 may read a provider-specific
value — if L1 or L2 needs to know it is running on AWS, the contract has been
violated and the abstraction has failed.

## The three outputs

| Output | Type | Meaning |
|---|---|---|
| `kubeconfig` | absolute path | A kubeconfig granting cluster-admin, sufficient for `up.sh` to install Argo CD. |
| `storageClass` | string | Name of the StorageClass L1/L2 put in every PVC. Must exist, must support `WaitForFirstConsumer`, must be dynamically provisioned. |
| `lbEndpoint` | `host:port` | Where traffic from outside reaches the cluster. L2's edge gateway binds behind this. |

### `kubeconfig`

An absolute path to a file, not the file's contents and not a `KUBECONFIG` export.
Callers do `kubectl --kubeconfig "$(...)"`, so the path must remain valid for the
life of the cluster.

The context inside it must be selected as `current-context`. L1's `up.sh` reads
`kubectl config current-context` and warns loudly if it does not match the cluster
it expects to be talking to.

### `storageClass`

The name only — never a manifest, never provisioner parameters. L0 owns making the
class exist and choosing its backing disk; L1 and L2 own only the name.

Requirements:

- `volumeBindingMode: WaitForFirstConsumer` — immediate binding pins a PV to a
  zone before the scheduler has placed the pod, which strands any workload with
  affinity or spread constraints.
- `allowVolumeExpansion: true` — required in any environment that holds real data;
  offline resize is not an option under a live system. kind's `local-path`
  provisioner cannot expand volumes, which is an accepted local asymmetry (below).
- Dynamic provisioning. No pre-created PVs.

**Note on the current consumer set: there isn't one.** Every database this
platform uses is external and managed outside Kubernetes, so no layer above L0
declares a PVC today. `storageClass` stays in the contract regardless — it is a
fact about the cluster, not about what happens to be deployed this week, and
removing an output is a breaking change to every implementation at once (see
"Changing this contract"). L1 and L2 still verify it, so the first workload that
does want a volume is not also the thing that discovers the class is wrong.

The class need not be the cluster default. L1 and L2 always name it explicitly, so
that a cluster with several classes stays unambiguous.

### `lbEndpoint`

A `host:port` string. It answers "if I curl the platform from a laptop, where do I
send the request" — not "which load balancer implementation is installed".

L0 guarantees the address is reachable and that traffic arriving there lands in the
cluster. It does **not** guarantee a `Service` of `type: LoadBalancer` will be given
an external IP — that is a per-provider capability, documented per implementation
below and deliberately outside the contract.

## How the outputs are published

Each implementation writes `contract.json` next to itself on a successful `up`:

```json
{
  "provider":     "local",
  "cluster":      "maal-local",
  "kubeconfig":   "/Users/you/infra/L0/local/kubeconfig",
  "storageClass": "standard",
  "lbEndpoint":   "127.0.0.1:8080"
}
```

`provider` and `cluster` are **operator-facing breadcrumbs, not contract outputs** —
they exist so a human reading the file knows which cluster it describes. Anything
above L0 that branches on `provider` is a bug.

`contract.json` is gitignored. It describes one live cluster, not the source that
produces clusters.

Read a field with `just contract <env> <field>`, or directly:

```sh
jq -r .kubeconfig L0/local/contract.json
```

## Implementations

| Env | Path | Provisioner | Status |
|---|---|---|---|
| `local` | `L0/local/` | kind | working |
| `aws` | `L0/aws/` | OpenTofu → EKS | unvalidated skeleton |
| `gcp` | `L0/gcp/` | OpenTofu → GKE | unvalidated skeleton |

### local (kind)

| Output | Value | Backed by |
|---|---|---|
| `kubeconfig` | `L0/local/kubeconfig` | `kind export kubeconfig` |
| `storageClass` | `standard` | kind's built-in `local-path-provisioner` |
| `lbEndpoint` | `127.0.0.1:8080` | kind `extraPortMapping` → NodePort `30080` |

The endpoint is a **NodePort mapping**, not a load balancer: kind's control-plane
container publishes host `127.0.0.1:8080` to container port `30080`, and L2's edge
gateway takes NodePort `30080`. Zero extra processes, deterministic address.

`type: LoadBalancer` Services therefore stay `<pending>` forever here. If you need
real LB semantics locally, run `just local-lb` to start
[`cloud-provider-kind`](https://github.com/kubernetes-sigs/cloud-provider-kind)
alongside the cluster — it watches for LB Services and assigns them docker-network
IPs. It is optional, it does not change `lbEndpoint`, and nothing in L1 requires it.

### Deliberate asymmetries with cloud

Keep these explicit rather than discovering them at migration time.

- **kindnet enforces no `NetworkPolicy`.** Locally a default-deny policy is
  documentation, not a control. EKS needs the VPC CNI network-policy agent or
  Calico; GKE needs Dataplane V2. Until then, pod-to-pod mTLS from Istio's ztunnel
  is the only real network control in the local cluster.
- **No cloud load balancer, no LB-IPAM.** See `lbEndpoint` above.
- **No workload identity.** There is no IRSA/Workload Identity equivalent in kind,
  so anything reaching a cloud API from a local cluster needs static credentials.
  This is why L2's dev-local secret store uses the `fake` provider rather than a
  real Secrets Manager — see `L2/Readme.md`.
- **Single node pool, no real topology.** `topology.kubernetes.io/zone` is
  meaningless on kind, so zone-spread constraints are untested until a cloud env.
- **No volume expansion.** kind's `local-path` provisioner writes to node-local
  disk and cannot resize a bound PVC; `gp3` and `pd-balanced` both can. A PVC
  resize is therefore something you cannot rehearse locally.

## Changing this contract

Adding a fourth output is a breaking change to every implementation at once — all
of them must emit it before L1 may read it. That cost is the point: it is what
keeps L1 portable. Prefer solving the problem inside one layer over widening the
seam between two.
