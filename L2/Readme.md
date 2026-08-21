# L2 — the Maal product

L1 hands up a cluster that can run things: a GitOps engine, a mesh, and
operators that provide `Certificate`, `ExternalSecret`, `AuthorizationPolicy`
and `Gateway`. **L2 is what actually runs** — the Go services, the third-party
applications they depend on, and the edge that lets traffic in.

The dividing line is capability vs instance. L1 installs the operators and
creates nothing; L2 declares what exists. That split is what keeps L1 reusable
under a different product, and it is worth defending when something feels like
it could go in either layer.

## Databases are external

**This cluster runs no database.** Every Postgres — Temporal's, Keycloak's, each
Go service's — is managed outside Kubernetes: RDS, Cloud SQL, or a container on
your laptop in dev. Nothing here creates one, and no layer of this repo holds a
PVC.

The consequences are the point:

- The cluster is **stateless**. Deleting all of L2 destroys no data; `just down`
  says so. There is no in-cluster backup, restore, or failover story because
  there is nothing in-cluster to have one for.
- **Addresses live in Git, credentials do not.** `host`, `port`, `name` and
  `sslmode` are facts about an environment and sit in the values file. The
  username, password and DSN are secrets and arrive through External Secrets,
  exactly like every other credential.
- **You create the databases.** Each values file carries the `CREATE ROLE` /
  `CREATE DATABASE` lines it expects at the top. A missing database surfaces as
  a schema job retrying forever rather than as an error anyone reads, so
  `bootstrap/up.sh` prints the hosts it expects on every run.

## What's here

| | Namespace | Source | Status |
|---|---|---|---|
| **edge** | `maal-edge` | `edge/dev-local/` | Gateway + TLS + routes |
| **Temporal** | `maal-temporal` | `go.temporal.io/helm-charts` `1.6.0` | wired, unverified |
| **Keycloak** | `maal-keycloak` | `codecentric` keycloakx `7.2.3` | wired, unverified |
| **maal-business** | `maal-business` | `../client` | reference service |
| **maal-stream-ph** | `maal-stream-ph` | `../maalstream_ph` | **parked, 0 replicas** |
| ~~maal-ledger~~ | — | `../ledger` | **parked, not in the catalog** |
| ~~Hyperswitch~~ | — | `juspay` hyperswitch-app | **parked, not in the catalog** |

"Wired, unverified" means the manifests render and validate against real CRD
schemas, but nothing has been run against a live cluster.

## Why nothing runs yet

All three service repos need work before any of them can start. This is stated
here rather than discovered at deploy time.

| Repo | Blocker |
|---|---|
| `client` | No Dockerfile, and **not a git repository at all** — no `.git`, no remote. Its Temporal and Postgres wiring are correct; it is the only one that would work given an image. |
| `maalstream_ph` | `temporal.Dial()` hardcodes `client.DefaultHostPort` and never imports `config`. That is a compile-time constant, so **no env var can redirect it** — a pod dials itself, `log.Fatalf`s, and crash-loops. Also no Dockerfile. |
| `ledger` | Hardcodes TigerBeetle at `127.0.0.1:4000` in `internal/adapters/tb/helpers.go:14` and **panics** when it cannot connect. Needs a TigerBeetle instance *and* a config block in the repo. |

**TigerBeetle is not deferred** — `ledger` already imports `tigerbeetle-go` and
uses it on the transaction path. That hardcoded native client is also why its
Dockerfile needs `CGO_ENABLED=1` and a glibc runtime base.

### Two ways a thing is parked

- **Removed from the catalog** when it cannot work at all — `maal-ledger`,
  `hyperswitch`. No Application is generated; the values file stays in `envs/`
  with the reason at the top.
- **`replicas: 0`** in its values file when the manifests are right but the repo
  is not — `maal-stream-ph`. The Application syncs green and runs no pods.

Both exist so that **red means broken**. An Application that is permanently red
and documented as expected teaches everyone to stop reading the dashboard, which
is the state in which a real failure goes unnoticed.

Only long-running processes are deployed at all. `client/cmd/starter`,
`maalstream_ph/cmd/app` and both `cmd/local` run once and exit — `cmd/app` is a
workflow starter despite the name, so deploying it as a Deployment would
crash-loop by design.

## Structure

```
L2/
├── apps/                         ← the root app syncs this directory
│   ├── secrets-appset.yaml       wave -1  ClusterSecretStore + dep credentials
│   ├── deps-appset.yaml          wave  0  Temporal, Keycloak
│   ├── services-appset.yaml      wave  1  the Go services
│   └── edge-appset.yaml          wave  2  Gateway, routes, TLS
├── charts/
│   └── go-service/               ← the shared chart every service uses
├── edge/dev-local/               the way in — see "The edge" below
├── envs/
│   ├── dev-local.yaml            environment definition
│   └── dev-local/                one values file per app
├── secrets/dev-local/            the env's secret backend + dep ExternalSecrets
├── root/{project,root-app}.yaml
└── bootstrap/up.sh
```

Same `{stage}-{provider}` matrix as L1, same "add an env = add a file" property.

## Namespace per service

Each service and each dependency gets its own namespace, enrolled in the ambient
mesh by Argo's `managedNamespaceMetadata` rather than by the chart — the
namespace is not the chart's to own. `maal-edge` is the exception and is
deliberately *not* in the dataplane: it is the thing that admits traffic into
the mesh, and enrolling it would put ztunnel in front of its own ingress path.

This is what makes the mesh policy legible. Every service has its own
ServiceAccount, which is also its mesh identity
(`cluster.local/ns/<ns>/sa/<name>`), and its `AuthorizationPolicy` names the
principals allowed to call it. Today every service denies all inbound traffic,
which is correct — nothing calls anything yet. Opening a path is one line:

```yaml
mesh:
  authorizationPolicy:
    allowedPrincipals:
      - cluster.local/ns/maal-business/sa/maal-business
```

That is L4 only. Ambient's ztunnel decides *whether* a principal may reach a
workload, not which path or method — that needs a waypoint proxy, and none
exists yet.

## Secrets

`ExternalSecret` → `ClusterSecretStore` → a backend that differs per env, and
nowhere else. **Including every database credential** — with no in-cluster
operator minting passwords, this is the only path a credential takes, in dev and
in cloud alike.

- **dev-local** uses the `fake` provider, serving literals from
  `secrets/dev-local/cluster-secret-store.yaml`. Not a shortcut: kind has no
  workload identity, so reaching a real Secrets Manager would need static cloud
  credentials — a worse secret than the ones it would fetch.
- **cloud** replaces that one file with an `aws:` or `gcpsm:` provider plus a
  `serviceAccountRef`. Every `ExternalSecret` refers to the store by name, so
  nothing else changes.

For the Go services this is automatic: `database.credentials` in a values file
names remote keys, and the chart renders them into that service's own
ExternalSecret and onto every workload as `DB__USER` / `DB__PASSWORD` /
`DB_DSN`. Both halves come from one helper, so the Secret's keys and the env var
names cannot drift. Temporal and Keycloak are upstream charts with their own
conventions, so their credentials are hand-written ExternalSecrets in
`secrets/dev-local/`, shaped to what each chart expects.

## The edge

`lbEndpoint` — the third L0 contract output — finally means something.

```
laptop                    kind                      cluster
──────                    ────                      ───────
https://…:8080  ──▶  hostPort 8080  ──▶  NodePort 30080  ──▶  Gateway (HTTPS 443)
                                                                   │
                                              ┌────────────────────┴────────────┐
                                     keycloak.maal.local        temporal.maal.local
```

HTTPS only, on one listener, because kind publishes exactly one port and a
plaintext edge would teach the wrong habit. cert-manager issues the certificate
from a self-signed local root — its first real consumer in this repo, and the
reason L1 installs the capability and creates no issuer: an issuer is policy,
and policy is per-environment.

```sh
just edge          # gateway, routes, certificate status
just edge-port     # pin the NodePort to 30080  ← the one imperative step
just hosts         # the /etc/hosts lines
just edge-ca       # the local root, if you would rather trust than -k
```

**`just edge-port` is the one imperative step left in a local bring-up.** istiod
provisions the gateway Service and assigns its nodePort dynamically, and the
Gateway API has no field to pin it. Istio's manual-deployment mode would make it
declarative; that is a deliberate piece of work rather than a values change, so
it is written down instead of guessed at.

Nothing here fronts a Maal Go service: `maal-business` is a Temporal worker with
no inbound port, and `maal-ledger` — the only one serving HTTP — is parked.

## Images

There is no registry. Build and load straight into kind:

```sh
just images                      # all three
just image ledger maal/ledger    # one
just restart maal-business       # ← roll pods onto the new image
```

`just restart` is not optional. `:dev` is a mutable tag, so reloading the image
does not change the Deployment spec: Argo reports Synced and the old pods keep
running. Cloud envs use an immutable tag — a commit SHA or a digest — and the
values change is what triggers the rollout.

**Only `ledger` has a Dockerfile** — and `ledger` is parked, so today
`just images` can build an image for nothing else. `client` and `maalstream_ph`
need one; the recipe says so rather than half-succeeding.

Copy `ledger/Dockerfile` and change the `./cmd/<entrypoint>` target — the chart
already assumes that layout (binary at `/app/<name>`, `config/*.yml` at
`/app/config`, `USER 1001`). Shipping those YAML files matters: `config.Load()`
panics if `config/<ENV>.yml` is missing relative to `SERVICE__ROOT`. Note
`client` and `maalstream_ph` are pure Go and can use `CGO_ENABLED=0`; only
`ledger` needs cgo, for TigerBeetle.

Cloud envs set `image.registry` to an ECR/GAR host and the same values files
become pulls.

## Run it

```sh
cd ../L0 && just local-up       # cluster + contract
cd ../L1 && just up             # platform  (needs a deploy key + pushed branch)
cd ../L2
# create the databases the values files name — bootstrap/up.sh lists the hosts
just images                     # build + load what exists
just up                         # verify contract + L1, apply the root
just status
just edge-port                  # once the gateway exists
```

`bootstrap/up.sh` refuses to run if L1's CRDs are missing, and names which ones
— because the alternative is every Application failing with `no matches for
kind` and no clue why.

## Ordering

Waves run `-1` (secret stores and credentials) → `0` (Temporal, Keycloak) →
`1` (services) → `2` (edge). Those waves are now **enforced**: L1 enables
progressive syncs declaratively, so an ApplicationSet's Applications are synced
in wave order rather than all at once. See `../L1/Readme.md`.

Two races remain and are self-correcting, because they cross wave boundaries in
the wrong direction:

- `secrets/dev-local/*.yaml` target the `maal-keycloak` and `maal-temporal`
  namespaces, which the deps appset creates at wave 0 — so at wave -1 they fail
  once with "namespace not found".
- Temporal's schema jobs need the external database to be reachable, not merely
  named.

Both retry into place. Neither is worth a synchronisation primitive.

## Prune policy

`prune: true` on the **services** appset only. Everything a service owns is
derived from its values file and reconstructible from Git, and without prune,
renaming a workload key leaves the old Deployment running forever with no
signal — the drift this layer is least able to notice.

`prune: false` everywhere else: the secret stores, the deps, and the edge, where
deleting a Gateway would take the NodePort the L0 contract promises. To exempt a
single resource inside a pruning app, annotate it
`argocd.argoproj.io/sync-options: Prune=false`.

No database is at risk either way — they are all outside the cluster.

## Known gaps

**No health probes — a decision, not an oversight.** None of the three services
exposes `/healthz` or `/readyz`, and probes are deliberately off for now. The
chart supports them per-workload (`livenessProbe` / `readinessProbe`) the moment
a service has an endpoint worth checking. Note `ledger`'s own
`docs/REST_API_STANDARD.md` §17 already prescribes `GET /healthz`.

**No migrations.** goose migrations exist in the service repos but no published
image carries them, so `migrations.enabled` is off everywhere. Publishing the
Dockerfile's build stage as a second tag is the usual fix.

**No observability.** L1 installs no metrics or tracing stack, so `just status`
and Argo's health are the only signals. This is the largest gap in L2.

**Dead `Srv` config.** `client` and `maalstream_ph` both declare `Srv.Host` /
`Srv.Port`, but `config.CNF.Srv` has zero usages in either repo — neither binds
a port. Their values files deliberately set no `Srv` block and no Service.

## Troubleshooting

| Symptom | Look at |
|---|---|
| No L2 Applications at all | `cd ../L1 && just logs-appset` |
| `maal-root` won't sync, "destination not permitted" | `root/project.yaml` is missing a namespace the app targets |
| `no matches for kind` | L1 hasn't converged — `cd ../L1 && just apps` |
| ExternalSecret stuck `SecretSyncedError` | `just secrets` — is the ClusterSecretStore there? |
| Pod `CreateContainerError` | image not loaded — `just images` |
| Pod `CreateContainerConfigError` | its Secret has no such key — `just secrets`, then check `database.credentials` against the store |
| Schema job retrying forever | the external database or role does not exist yet — see the top of its values file |
| New image, old behaviour | `just restart <service>` — `:dev` is mutable |
| Nothing reachable from the laptop | `just edge-port`, then `just hosts` |
| A service can't reach another | its `allowedPrincipals` is empty by default |
