# L0/aws — EKS

**STATUS: unvalidated skeleton.** This has never been applied against a real AWS
account. The interface is settled and the outputs are the contract; the resource
details need a real `tofu plan` before you trust them.

## Before first run

1. **Configure remote state.** `versions.tf` declares `backend "s3" {}` as a
   partial configuration, so `tofu init` fails until you give it a bucket. That
   is deliberate: a commented-out backend lets init succeed against local state
   and you find out in an incident.
   ```sh
   cp backend.hcl.example backend.hcl     # it lists the bucket to create first
   ```
2. **Set `edge_hostname`.** It has no default because it is the one contract
   output L0 cannot discover — see `outputs.tf`.
3. **Turn on `deletion_protection`** on anything holding data before prod.

```sh
cp terraform.tfvars.example terraform.tfvars   # then edit
cd ../ && just aws-plan
```

## The two-phase apply

The `kubernetes` provider is configured from `module.eks` outputs, so on an empty
state OpenTofu cannot plan `kubernetes_storage_class_v1` — the provider has no
endpoint to talk to yet. The first apply therefore has to build the cluster
before it can plan anything inside it:

```sh
tofu apply -target=module.vpc -target=module.eks
tofu apply
```

**`just aws-up` does this for you** — it detects empty state and runs both
phases, because a `-target` you have to remember is a `-target` you forget.
Subsequent applies are single-phase.

The cleaner alternative is splitting the StorageClass into its own root module,
at the cost of a second state file and a second init. Worth doing if this module
ever grows other in-cluster resources. Moving it up into L1 is *not* an option —
L0 owns storage and L1 only knows a name.

## What differs from local

| | local (kind) | aws (EKS) |
|---|---|---|
| NetworkPolicy | not enforced (kindnet) | enforced (VPC CNI agent) |
| Volume expansion | unsupported | supported (gp3) |
| Workload identity | none | IRSA (`enable_irsa`) |
| `lbEndpoint` | real, fixed port mapping | a DNS name you point at L2's gateway |
| Topology | single fake zone | `az_count` real AZs |

## Cost note

`single_nat_gateway` is on for every env except `prod`. NAT gateways are the
usual surprise on an EKS bill — three of them across three AZs costs more than
the nodes on a small cluster.
