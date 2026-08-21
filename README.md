# infra

Kubernetes infrastructure for the Maal platform, built as three layers with a
hard contract between each. Local today (kind), AWS and GCP later — with the
layers above L0 unchanged when that happens.

```
                                          ┌─ external, not ours ──┐
┌─ L2 ── the product ──────────────────────┐                      │
│  edge (Gateway + TLS)                    │   Postgres           │
│  Temporal · Keycloak · maal-business     │──▶ (RDS / Cloud SQL / │
│  One shared Go chart, namespace per svc. │    a laptop container)│
└──────────────────────────────────────────┘                      │
   ▲  capabilities: ExternalSecret · AuthorizationPolicy          │
   │                Certificate · Gateway                          │
┌─ L1 ── the platform ─────────────────────┐   No database        │
│  Argo CD · Istio (ambient) · cert-manager│   operator, and no   │
│  · External Secrets · Gateway API        │   database PVC.      │
│  One imperative act, then Git reconciles.│                      │
└──────────────────────────────────────────┘                      │
              ▲  kubeconfig · storageClass · lbEndpoint           │
┌─ L0 ── the cluster ──────────────────────┐                      │
│  kind (working) · EKS, GKE (skeletons)   │                      │
└──────────────────────────────────────────┘  └───────────────────┘
```

The arrows are the whole design. **L1 is written against exactly three facts
about the cluster** — `kubeconfig`, `storageClass`, `lbEndpoint` — and nothing
else. Swapping kind for EKS is then a new L0 implementation that publishes the
same three facts, with no change above it.

- [`L0/contract.md`](L0/contract.md) — normative definition of those three facts
- [`L0/README.md`](L0/README.md) — provisioning, per provider
- [`L1/Readme.md`](L1/Readme.md) — the platform and its ApplicationSet matrix
- [`L2/Readme.md`](L2/Readme.md) — the product, its services and their secrets
- [`L2/charts/go-service/README.md`](L2/charts/go-service/README.md) — the chart every Go service uses

## Quickstart

```sh
cd L0 && just local-up      # kind cluster + publish the contract
cd ../L1 && just up         # Argo CD, then GitOps takes over
cd ../L2 && just images && just up
```

`L1/just up` needs an SSH deploy key for this repo — it prints exactly what to
do if one isn't there.

## Environments

L1 fans out over a `{stage} × {provider}` matrix, one file per cell in
`L1/envs/`. Only `dev-local` exists today; `staging-aws` is a new file, not a new
tree.

## State of things

| | Status |
|---|---|
| L0 local (kind) | working, verified end to end |
| L0 aws (EKS) | unvalidated skeleton — never applied, never `tofu plan`ed |
| L0 gcp (GKE) | unvalidated skeleton — same |
| L1 | written and bootstraps; needs a deploy key + a pushed branch to converge |
| L2 | written; charts render and validate against real CRD schemas, nothing run yet |
| L2 services | `maal-business` is the only one in the catalog. `maal-ledger` and `maal-stream-ph` are parked — see [L2/Readme.md](L2/Readme.md#why-nothing-runs-yet). None can start until their repos gain Dockerfiles and config fixes. |
| Databases | **external, not in this repo's scope.** L2 names hosts and pulls credentials; you create the databases. |
| Mesh CA | istiod still self-signs. The cert-manager chain is written and parked in [`L1/platform/mesh-ca/`](L1/platform/mesh-ca/) — the largest open gap. |
| Observability | none. `just status` and Argo health are the only signals — the second-largest gap. |

## Conventions

- **Layers install capabilities, not instances.** L1 installs cert-manager; it
  creates no issuer. L1 installs the Gateway API CRDs; it creates no Gateway.
- **The cluster is stateless.** Every database is external. Nothing here holds a
  PVC, so nothing here can lose data — and no layer of this repo owns a backup,
  restore, or failover story, because none of them are its to own.
- **`prune: false` except where drift is invisible.** Convergence is additive by
  default, because the blast radius of a bad generator is otherwise the mesh.
  The one exception is L2's services, which own nothing that isn't
  reconstructible from their values file and where an orphaned Deployment would
  otherwise run forever unnoticed.
- **Pins are explicit and verified.** Every chart version is pinned, and the
  comment next to it says how to check whether it's current.
- **Asymmetries are written down.** Where local differs from cloud — no
  NetworkPolicy enforcement, no volume expansion, no workload identity — it's in
  `L0/contract.md`, not in someone's head.
- **No credential is in Git.** Everything — database passwords included — comes
  through External Secrets. The repo holds names and locations only.
- **Gaps are stated, not papered over.** Where something is a placeholder or
  unvalidated, the file says so in the file.
- **Nothing is deployed that cannot work.** A service whose repo isn't ready is
  parked — removed from the catalog, or held at zero replicas — rather than left
  to crash-loop and normalise a red dashboard. Red means broken.
- **Conventions are enforced, not just written.** Every Application syncs with
  `automated` + `selfHeal`, so a bad commit reaches the cluster with no human in
  the path. [`.github/workflows/ci.yml`](.github/workflows/ci.yml) is the gate:
  it renders every chart, validates against real CRD schemas, shellchecks the
  bootstrap scripts, and fails if a credential-shaped file is ever tracked.
