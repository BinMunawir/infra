# The L0 contract, as OpenTofu outputs. These names must match L0/aws/outputs.tf
# and L0/local/up.sh exactly. See ../contract.md.

output "storageClass" {
  description = "L0 CONTRACT — StorageClass name for every PVC in L1/L2."
  value       = kubernetes_storage_class_v1.balanced.metadata[0].name
}

output "kubeconfig" {
  description = "L0 CONTRACT — absolute path to a cluster-admin kubeconfig."
  value       = abspath(local_sensitive_file.kubeconfig.filename)
}

output "lbEndpoint" {
  description = <<-EOT
    L0 CONTRACT — host:port where outside traffic reaches the cluster.

    A DNS name you own, pointed at L2's gateway load balancer once it exists.
    See L0/aws/outputs.tf for the full reasoning; the tension is identical on
    both clouds and absent locally.
  EOT
  value       = "${var.edge_hostname}:443"
}

# ─── breadcrumbs (not contract outputs) ────────────────────────────────────

output "provider" {
  description = "Operator breadcrumb. Nothing above L0 may branch on this."
  value       = "gcp"
}

output "cluster" {
  description = "Operator breadcrumb — which cluster this contract describes."
  value       = google_container_cluster.this.name
}
