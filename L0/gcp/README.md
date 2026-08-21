# L0/gcp — GKE

**STATUS: unvalidated skeleton.** Never applied against a real project. The
interface is settled and the outputs are the contract; the resource details need
a real `tofu plan` first.

## Before first run

1. **Configure remote state.** `versions.tf` declares `backend "gcs" {}` as a
   partial configuration, so `tofu init` fails until you point it at a bucket —
   deliberately, so it cannot quietly fall back to local state.
   ```sh
   cp backend.hcl.example backend.hcl     # it lists the bucket to create first
   ```
2. **Set `project_id` and `edge_hostname`** — neither has a default.
3. **Enable the APIs**: `container.googleapis.com`, `compute.googleapis.com`.
4. **Install `gke-gcloud-auth-plugin`** — the generated kubeconfig execs it.
5. **Set `deletion_protection = true`** in `main.tf` before prod. It is off here
   so a throwaway skeleton cluster can actually be destroyed.

```sh
cp terraform.tfvars.example terraform.tfvars   # then edit
cd ../ && just gcp-plan
```

## The two-phase apply

Same shape as AWS — the `kubernetes` provider depends on the cluster this module
creates:

```sh
tofu apply -target=google_container_cluster.this -target=google_container_node_pool.default
tofu apply
```

`just gcp-up` detects empty state and runs both phases automatically, so this is
background rather than a step to remember.

## Why native resources instead of a module

A regional GKE cluster with one node pool is about 90 lines. A module would add
a dependency and a layer of variable indirection to save very little. EKS is the
opposite case — VPC, IRSA, addons, and node groups are genuinely verbose — which
is why `L0/aws` uses `terraform-aws-modules`. The asymmetry is deliberate.

## Node count is per-zone

`node_count` on a regional cluster is nodes **per zone**, so `node_count = 2`
across a 3-zone region gives you 6 nodes. This differs from `L0/aws`, where the
managed node group counts total nodes. Worth remembering when comparing bills.

## What differs from local

| | local (kind) | gcp (GKE) |
|---|---|---|
| NetworkPolicy | not enforced (kindnet) | enforced (Dataplane V2) |
| Volume expansion | unsupported | supported (pd-balanced) |
| Workload identity | none | Workload Identity (`workload_pool`) |
| `lbEndpoint` | real, fixed port mapping | a DNS name you point at L2's gateway |
| Topology | single fake zone | real regional spread |
