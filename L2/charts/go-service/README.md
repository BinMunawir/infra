# go-service

Deploys one Maal Go service built to the Go Service Standard
(`client/blueprint.md`). One chart, one values file per service per env.

`values.yaml` is the full contract and is commented key by key — read it first.
This file explains the three decisions the chart is built around.

## 1. A service is N workloads, not one Deployment

The standard puts several entrypoints under `cmd/` — `worker` (Temporal),
`server`/`app` (HTTP), `local` and `starter` (dev tools). They share an image
and differ only in command, so `workloads` is a map:

```yaml
workloads:
  worker:
    command: ["/app/worker"]
    http: {enabled: false}
  app:
    command: ["/app/app"]
    http: {enabled: true, port: 9000}
```

Each becomes `<service>-<workload>`, scaled and probed independently. Only
`http.enabled` workloads get a Service — a Temporal worker holds outbound
connections and accepts nothing, so giving it one would be a lie the mesh then
has to model.

## 2. Config is a ConfigMap; secrets are env vars

cleanenv resolves **env var → `config/<ENV>.yml` → struct default**, so the two
paths never collide and the precedence is the standard's, not the chart's.

- `config.values` renders to `config/<env>.yml` in a ConfigMap, mounted over
  the image's own config directory. Deploy-time, not build-time.
- `secrets.data` renders an `ExternalSecret`; each key becomes an env var.
  Because env vars win, a secret always overrides whatever the YAML says.

Nothing secret is ever in the ConfigMap, and nothing secret is ever in Git —
only the *name* of a secret and where to find it in the store.

## 3. The database is external; its address is not a secret, its password is

The cluster runs no database. `database.enabled` does not create anything — it
describes how to reach a Postgres somebody else manages, and splits that
description along the line that matters:

```yaml
database:
  enabled: true
  host: host.docker.internal   # a fact about the environment → Git
  port: 5432
  name: maalbizdb
  sslmode: disable
  credentials:                 # secrets → the store, never Git
    userKey: maal/business/db/username
    passwordKey: maal/business/db/password
    dsnKey: maal/business/db/dsn
```

`host`/`port`/`name`/`sslmode` render as plain env vars. The three `*Key` values
are **remote keys in the env's ClusterSecretStore**, not values — they become
entries in this service's `ExternalSecret` and arrive as `DB__USER`,
`DB__PASSWORD` and `DB_DSN`.

Both halves are generated from one helper (`go-service.dbCredentialEnv`), so the
Secret's keys and the workload's env var names cannot drift. Set a `*Key` to
`""` to skip it: a service that only reads `DB_DSN` needs just `dsnKey`.

So there is still no database password anywhere in this repo, and rotating one
is a change in the backing store rather than a commit.

The chart fails to render — rather than producing a broken workload — if
`database.credentials` is set without `secrets.enabled`, or if `database.enabled`
is set without a `host`.

## Parking a service

Two mechanisms, and the difference matters:

- **`replicas: 0`** — the manifests are right but the repo or its image is not.
  Config, ServiceAccount, secrets and mesh policy are all created; no pods run.
  The Application syncs green rather than advertising a crash loop as normal.
  Note `replicas: 0` is honoured literally — the template avoids sprig's
  `default`, which treats `0` as empty and would silently render `1`. With the
  database external, parking now costs an ExternalSecret and nothing else.
- **Removed from the catalog** in `L2/apps/services-appset.yaml` — the service
  cannot work at all. No Application is generated; the values file stays put
  with the reason at the top.

Only long-running processes belong in `workloads` at all. A `cmd/` that runs
once and exits — a workflow starter, a generator, a dev harness — is a Job, and
deploying it as a Deployment produces a crash loop by design.

## Adding a service

1. Add an entry to `L2/apps/services-appset.yaml`.
2. Add its namespace to `L2/root/project.yaml`.
3. Copy `L2/envs/dev-local/maal-business.yaml` — the worked reference — and cut
   it down.

`just check-envs` lists services with no values file; `just render` catches
template errors before Argo sees them.

## Known gaps

| Gap | Why |
|---|---|
| No probes on any service | A decision, not an oversight: none of the three repos exposes `/healthz`, and a TCP check would call a wedged process healthy. The chart supports `livenessProbe`/`readinessProbe` per workload the moment there is an endpoint worth checking. |
| `migrations.enabled` off everywhere | goose and `internal/adapters/pg/migrations` are not in any published runtime image. The Job would run and fail. |
| HPA needs metrics-server | kind does not ship it and L1 does not install it, so autoscaling on `dev-local` produces an HPA stuck at `<unknown>`. |
| L4 authz only | Ambient enforces principal-level access at ztunnel. Path- and method-level rules need a waypoint proxy, which nothing has yet. |
| `topologySpreadConstraints` untested | Declared per workload and inert on kind, which has one fake zone (`L0/contract.md`). Written down here rather than remembered at migration time. |
| Mutable `:dev` tag | Reloading an image does not change the Deployment spec, so Argo reports Synced and the old pods keep running. `just restart <service>` locally; immutable tags in cloud. |
