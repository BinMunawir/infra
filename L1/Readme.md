# L1 — the GitOps platform

L0 hands up a cluster and three facts about it. **L1 turns that cluster into a
GitOps-driven platform.** It has exactly one imperative act — install a pinned
Argo CD and give it a key to this repo — after which the mesh, the operators, and
Argo's own configuration all reconcile from Git. Nothing is hand-applied past
bootstrap.

L1 is **application-agnostic**: the GitOps engine plus the CRD-providing
operators, identical under any app you'd run here. It installs *capabilities*,
never instances — cert-manager but no issuer, the Gateway API CRDs but no
`Gateway`. The Maal platform proper (Temporal, Keycloak, the edge, the Go
services) is **L2**.

## Components

| Component | Role | Source | Pin |
|---|---|---|---|
| Argo CD | GitOps engine, self-managed | `argoproj/argo-cd` install.yaml | `v3.3.14` |
| cert-manager | X.509 issuance + webhook certs | `charts.jetstack.io` | `v1.21.1` |
| Istio `base` | CRDs + cluster roles | `istio-release…/charts` | `1.30.3` |
| Istio `cni` (ambient) | in-pod redirection to ztunnel | `istio-release…/charts` | `1.30.3` |
| `istiod` (ambient) | control plane — **not** a CA any more | `istio-release…/charts` | `1.30.3` |
| `ztunnel` (ambient) | node proxy — mesh-wide L4 mTLS | `istio-release…/charts` | `1.30.3` |
| mesh-ca | the mesh's cert-manager CA chain | this repo, `platform/mesh-ca/` | — |
| istio-csr | signs every mesh certificate from that chain | `charts.jetstack.io` | `v0.17.0` |
| External Secrets operator | enables L2 `ExternalSecret`s | `charts.external-secrets.io` | `2.9.0` |
| Gateway API CRDs | `Gateway`/`HTTPRoute` kinds for the edge | vendored `kubernetes-sigs/gateway-api` | `v1.6.1` |

Pins live in the catalog in `platform/appset.yaml`, except Argo's, which lives in
`bootstrap/up.sh` (`ARGO_VERSION`) because Argo installs itself before Git is in
the loop.

**Not here, deliberately:** no Kafka/Strimzi. No observability stack. No
Kyverno.

**No database operator, deliberately.** Every Postgres this platform talks to is
external and managed outside the cluster. So the cluster runs no stateful
database workload, holds no database PVC, and cannot lose data it never stored —
and L1 owns no backup, restore, or failover story, because none of those are its
to own. Reintroducing an in-cluster operator would be an architecture change
rather than a catalog addition; it moves durability into the cluster and drags
all three of those in with it.

### Argo's own configuration

`bootstrap/argocd/` holds the pinned upstream `install.yaml` *plus* a
`kustomization.yaml`, and Argo renders the directory with kustomize. That split
is what makes controller flags durable: `install.yaml` stays byte-identical to
the release so a version bump is a clean re-vendor, and anything we change lives
in the overlay next to it. Progressive syncs are turned on there — see the
ordering section.

The Gateway API CRDs live here rather than in L2 because they are cluster-scoped
— keeping them in L1 lets L2's AppProject forbid cluster resources entirely,
which is what stops an L2 mistake from reaching the mesh or the operators. L1
installs the kinds; no `Gateway` object exists yet.

## Structure

```
L1/
├── envs/                         ← one file per {stage}-{provider} cell
│   ├── dev-local.yaml            environment definition
│   └── dev-local/                per-component Helm values for that env
│       ├── cert-manager.yaml
│       ├── istiod.yaml
│       └── …
├── platform/
│   ├── appset.yaml               ← the matrix: envs × Helm components
│   ├── appset-vendored.yaml      the same matrix for vendored manifests
│   ├── argocd.yaml               Argo manages Argo (hub only, not per-env)
│   └── mesh-ca/                  the mesh CA chain — a component in appset-vendored
├── vendor/
│   └── gateway-api/              pinned CRDs — `just vendor-gateway-api`
├── root/
│   ├── project.yaml              AppProject "platform"
│   └── root-app.yaml             app-of-apps root — the one thing applied by hand
└── bootstrap/
    ├── up.sh                     THE imperative seam
    ├── down.sh
    └── argocd/
        ├── install.yaml          vendored on first up.sh — commit it
        └── kustomization.yaml    our overlay: controller flags that must persist
```

### The matrix

`platform/appset.yaml` crosses two generators:

1. **git files** over `envs/*.yaml` — every environment
2. **list** — the component catalog

`appset-vendored.yaml` is the same matrix for components that are vendored
manifests rather than upstream charts — currently just the Gateway API CRDs.
Two generators rather than one template that branches on whether `.chart` is
set, because the branch is harder to read than the duplication.

The product is one Application per (env, component), named
`{stage}-{provider}-{component}` — `dev-local-istiod`, and later
`prod-aws-istiod`. Adding an environment is one new file in `envs/`. Adding a
component is one new list element. Neither touches the other, and neither
requires editing six Application manifests by hand.

Per-env Helm values are read from this repo through a second Argo source:

```yaml
valueFiles:
  - $values/L1/envs/{{.stage}}-{{.provider}}/{{.component}}.yaml
```

Missing files are ignored, so a component with nothing to override needs no file
— though `just check-envs` will list the gaps, because an empty override should
be a visible choice rather than an invisible one.

Chart versions default to the catalog. An env overrides one by naming it:

```yaml
# envs/dev-local.yaml
versions:
  istiod: 1.31.0        # dev tries the new Istio; prod stays on 1.30.3
```

## Adding an environment

1. `cp envs/dev-local.yaml envs/staging-aws.yaml`, edit `stage`, `provider`, and
   the `contract:` block to match what `L0/aws` published.
2. `mkdir envs/staging-aws/` and add values files for anything that differs.
3. Register the target cluster with Argo (`argocd cluster add`) and set
   `destination.server` in the env file.
4. Commit and push. The ApplicationSet notices the new file and fans out.

No change to `platform/`, `root/`, or `bootstrap/`.

## The L0 contract, mirrored

L0 publishes `contract.json` — but it's generated and gitignored, and **Argo only
ever reads Git**. So each env file carries a copy:

```yaml
contract:
  storageClass: standard
  lbEndpoint: "127.0.0.1:8080"
```

`bootstrap/up.sh` refuses to run if the copy and the live cluster disagree. Git
stays the source of truth for what the platform believes; L0 is the thing checked
against it. Without that check, a stale copy would have L2 writing PVCs against a
StorageClass that doesn't exist, and you'd find out at the first Postgres restore.

## Sync ordering

Two mechanisms, and the difference matters:

**Within one Application**, `argocd.argoproj.io/sync-wave` annotations order
resource creation properly. This works out of the box and always has.

**Across Applications**, sync waves do nothing on their own — an ApplicationSet's
controller creates every Application at once. Without help, ordering degrades to
**retry with back-off**: `istiod` races ahead of `istio-base`, fails because the
Istio CRDs aren't there yet, backs off (10s, then 20s, capped at 3m, up to 10
attempts) and succeeds on a later pass. It converges, and it converges noisily —
red Applications for the first minute or two of every cold bring-up. `retry.limit`
is 10 rather than 5 precisely because it was load-bearing.

Relying on that permanently is a bad trade: it trains everyone to read a red
dashboard as normal, which is the state in which a genuinely broken Application
goes unnoticed. So it is turned off.

`platform/appset.yaml` carries a `RollingSync` strategy keyed on the
`platform.maal/wave` label, and progressive syncs are **enabled in Git** —
`bootstrap/argocd/kustomization.yaml` sets
`applicationsetcontroller.enable.progressive.syncs: "true"` in
`argocd-cmd-params-cm`, which is where the applicationset controller reads it
from. Because it is part of the manifests Argo self-manages, it survives
self-heal; the old `kubectl patch` approach did not.

```sh
just progressive     # verifies it is actually on, rather than turning it on
```

If it ever reads OFF, ordering has silently fallen back to retry-with-backoff.
That is a working state, not a broken one — just a noisier one.

The waves, and why each one waits:

| Wave | Components | Why not earlier |
|---|---|---|
| 0 | cert-manager, istio-base, gateway-api | nothing to wait for |
| 1 | mesh-ca, istio-cni, external-secrets | the CA needs cert-manager's CRDs + webhook |
| 2 | istio-csr | needs the issuer from wave 1 |
| 3 | istiod | starts self-signed if istio-csr is not already serving |
| 4 | ztunnel | needs istiod |

Waves 2–4 exist entirely because of the mesh CA — see below. `mesh-ca` sits in
the *vendored* appset, which has no `RollingSync` strategy, so its wave is an
annotation only and it relies on retry to converge on a cold cluster.

## Mesh: ambient, not sidecar

Ambient's **ztunnel gives mesh-wide L4 mTLS with no sidecars** — near-zero
per-workload config, lighter on a small cluster. On kind this is the *only* real
network control, because kindnet enforces no NetworkPolicy (see
`../L0/contract.md`). L7 (waypoints), authz, and routing are added per-service in
L2.

To switch to **sidecar** mode: drop the `ztunnel` element from the catalog, drop
`profile: ambient` from `envs/*/istiod.yaml` and `envs/*/istio-cni.yaml`, and
label namespaces for injection in L2. One redirect, contained to this layer.

**Mesh CA: cert-manager, not istiod.** istiod's CA server is off
(`ENABLE_CA_SERVER=false`) and every certificate in the mesh — ztunnel's
included — is signed by `cert-manager-istio-csr` from the chain in
[`platform/mesh-ca/`](platform/mesh-ca/):

```
maal-mesh-root (10y, offline in cloud) ──▶ maal-mesh-intermediate (1y) ──▶ istio-csr ──▶ workloads
```

This closes what was L1's largest gap. istiod's default is to self-sign a root,
hold it in `istio-ca-secret`, and **regenerate it if that Secret is ever lost** —
after which every workload certificate chains to a root nothing else trusts and
mesh mTLS is broken until every pod rotates, with no way to bring the old root
back. The root now has a lifecycle, an owner, and a rotation path.

Two details worth knowing before touching it:

- **ztunnel must be told too.** `caAddress` in `envs/*/ztunnel.yaml` pairs with
  `caTrustedNodeAccounts` in `envs/*/istio-csr.yaml`. Miss either and every
  component still reports Healthy while no ambient workload gets a certificate.
- **istio-csr runs in `istio-system`**, not the chart's default namespace, so it
  can mount the root it publishes as the trust bundle. That is what removes the
  imperative Secret-copying step the upstream guide needs.

`just verify` section 7 asserts the mesh is actually using this CA rather than a
self-signed one — the failure it guards against is invisible in Application
health. [`platform/mesh-ca/README.md`](platform/mesh-ca/README.md) has the wave
ordering, how to read a live workload's certificate out of ztunnel, and the
swap to a Vault/PCA root for cloud.

## Run it

Prereq: L0 must be up and have published a contract.

```sh
cd ../L0 && just local-up
cd ../L1
```

1. **Give Argo a key for this repo.** Argo clones from inside the cluster, so it
   cannot borrow your ssh-agent — the private key is copied into a Secret.

   On `local`, nothing to do: it falls back to `~/.ssh/id_ed25519` if no deploy
   key exists. The kind node is disposable and only you can reach its etcd.

   **On any cloud env, mint a dedicated read-only deploy key.** There is no
   fallback there, by design — a personal key in a shared cluster's etcd is
   write access to every repo you own, one `kubectl get secret` away:
   ```sh
   ssh-keygen -t ed25519 -N '' -C 'argocd@maal' -f ~/.ssh/maal_argocd_deploy
   pbcopy < ~/.ssh/maal_argocd_deploy.pub
   # paste at https://github.com/BinMunawir/infra/settings/keys
   ```
   A deploy key present at that path always wins over the local fallback, and
   `ARGOCD_SSH_KEY=/some/other/key` overrides both. `up.sh` logs which it picked.
2. `just up` — verifies the contract, installs pinned Argo, registers the key,
   applies the AppProject and the app-of-apps root.
3. **Commit + push** `bootstrap/argocd/install.yaml` so the self-managing `argocd`
   Application can reconcile it from the remote.
4. `just status` / `just apps` to watch it converge.

**Argo reads the pushed branch, not your working tree.** Nothing converges until
your commits are on `main`.

## Troubleshooting

| Symptom | Look at |
|---|---|
| No Applications appear at all | `just logs-appset` — generator or repo-auth errors land there |
| One app stuck Unknown/Degraded | `just why dev-local-istiod` |
| `argocd` app OutOfSync forever | `bootstrap/argocd/` isn't pushed yet |
| `argocd` app fails with "conflict" | Field-manager mismatch: bootstrap applies as `argocd-controller` and the app syncs with `Force=true`, so this should not happen — if it does, check who owns the field with `kubectl get deploy argocd-server -o yaml \| grep -A5 managedFields` |
| Everything red on first bring-up | Progressive syncs are off — `just progressive` |
| Nothing converged, no obvious error | `just drift` lists exactly what is not Synced+Healthy |
| Repo access denied | Deploy key not added on GitHub, or `maal-infra-repo` Secret missing |
