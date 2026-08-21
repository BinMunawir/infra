# The L0 contract, as OpenTofu outputs. `just aws-up` pipes these through jq
# into contract.json, so THESE NAMES ARE THE CONTRACT — they must match
# L0/local/up.sh and L0/gcp/outputs.tf exactly. See ../contract.md.

output "storageClass" {
  description = "L0 CONTRACT — StorageClass name for every PVC in L1/L2."
  value       = kubernetes_storage_class_v1.gp3.metadata[0].name
}

output "kubeconfig" {
  description = "L0 CONTRACT — absolute path to a cluster-admin kubeconfig."
  value       = abspath(local_sensitive_file.kubeconfig.filename)
}

output "lbEndpoint" {
  description = <<-EOT
    L0 CONTRACT — host:port where outside traffic reaches the cluster.

    NOTE: this is the one output the cloud implementations cannot compute at
    apply time. Locally it is a fixed kind port mapping. On EKS the address
    belongs to a load balancer that does not exist until L2 creates its edge
    gateway Service — and it changes whenever that Service is recreated.

    Resolving that by having L0 pre-provision an NLB would put the edge in the
    wrong layer and give you two load balancers once the AWS LB controller
    creates its own. So instead L0 publishes the *stable* address: a DNS name
    you own, which you point at the gateway's LB once L2 is up. That keeps the
    contract a fact about the environment rather than a race with L2.
  EOT
  value       = "${var.edge_hostname}:443"
}

# ─── breadcrumbs (not contract outputs) ────────────────────────────────────

output "provider" {
  description = "Operator breadcrumb. Nothing above L0 may branch on this."
  value       = "aws"
}

output "cluster" {
  description = "Operator breadcrumb — which cluster this contract describes."
  value       = module.eks.cluster_name
}
