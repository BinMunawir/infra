# L0 — cluster provisioning

L0 makes a Kubernetes cluster exist and publishes three facts about it. That's
the whole job. It knows nothing about Argo, the mesh, Postgres, or any service.

**[`contract.md`](contract.md) is the important file here** — it defines the
three outputs (`kubeconfig`, `storageClass`, `lbEndpoint`) that everything above
this layer is written against. Read it before changing anything.

## Layout

```
L0/
├── contract.md              ← normative; the whole point of this layer
├── justfile                 ← the interface: *-up, *-down, contract, verify
├── local/                   kind          — working
│   ├── kind.yaml
│   ├── up.sh · down.sh
│   └── contract.json        (generated, gitignored)
├── aws/                     OpenTofu → EKS — unvalidated skeleton
└── gcp/                     OpenTofu → GKE — unvalidated skeleton
```

Each implementation is independent. They share no code — only the shape of
`contract.json` and the first five variable names. Sharing more would mean an
abstraction that has to be right for all three clouds at once, and that is a
worse bet than three honest implementations that agree on five names.

## Local quickstart

```sh
cd L0
just local-up          # create the cluster, publish the contract
just show              # what did it publish?
just verify            # does the live cluster still match?
```

Then hand off to L1:

```sh
cd ../L1 && just up
```

Tear down with `just local-down`. There is no L1 teardown to run first —
deleting the cluster takes Argo, the mesh, and the operators with it.

## Reading the contract from above

Never hardcode a path. Ask:

```sh
just contract local kubeconfig     # /Users/…/infra/L0/local/kubeconfig
just contract local storageClass   # standard
just contract local lbEndpoint     # 127.0.0.1:8080
```

L1's `bootstrap/up.sh` does exactly this, which is why swapping `local` for
`aws` later changes nothing above L0.

## Adding a provider

1. `mkdir L0/<name>/`, implement however you like.
2. Emit `contract.json` with the same five keys on success; delete it on
   teardown. A stale contract pointing at a dead cluster is worse than none.
3. Meet the `storageClass` requirements in `contract.md` — `WaitForFirstConsumer`
   above all, or a PV gets pinned to a zone before the scheduler has placed the
   pod that needs it.
4. Add `<name>-up` / `<name>-down` to the justfile.
5. Add a row to the implementations table in `contract.md`, and be honest in it
   about status.

You do **not** need to touch L1.

## Prerequisites

| | local | aws | gcp |
|---|---|---|---|
| `kubectl`, `jq`, `just` | ✓ | ✓ | ✓ |
| `docker` (Desktop or colima) | ✓ | | |
| `kind` | ✓ | | |
| `tofu` ≥ 1.8 | | ✓ | ✓ |
| `aws` CLI | | ✓ | |
| `gcloud` + `gke-gcloud-auth-plugin` | | | ✓ |

Give the local VM headroom before L1 — roughly 6 CPU / 12 GiB:

```sh
colima stop && colima start --cpu 6 --memory 12
```

`local/up.sh` warns if Docker reports less.
