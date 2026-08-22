# Input interface. The first four variables are deliberately identical in
# L0/gcp/variables.tf — that shared surface is what makes the providers
# swappable. Anything below the divider is provider-specific and must never
# leak above L0.

variable "env" {
  description = "Environment name — matches an L1 envs/ values file (dev, staging, prod)."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name. Becomes the `cluster` breadcrumb in contract.json."
  type        = string
  default     = "maal"
}

variable "kubernetes_version" {
  description = "Control plane minor version. Keep within one minor of the local kind cluster."
  type        = string
  default     = "1.31"
}

variable "node_count" {
  description = "Desired worker count. Mirrors the two kind workers by default."
  type        = number
  default     = 2
}

variable "edge_hostname" {
  description = <<-EOT
    DNS name you own, which becomes the `lbEndpoint` contract output. You point
    it at L2's gateway load balancer once that exists. See outputs.tf for why
    L0 publishes a name rather than discovering an address.
  EOT
  type        = string
}

# ─── AWS-specific ──────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region."
  type        = string
  default     = "me-south-1" # Bahrain — closest region with SAMA-relevant latency
}

variable "vpc_cidr" {
  description = "CIDR for the cluster VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread node groups across."
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "Worker instance type. Sized for Argo + Istio + cert-manager + External Secrets."
  type        = string
  default     = "m6i.large"
}

variable "enable_network_policy" {
  description = <<-EOT
    Enable the VPC CNI network-policy agent. Unlike kindnet — the CNI L0
    provisions locally, which accepts NetworkPolicy objects and enforces
    nothing — this genuinely enforces them. That asymmetry is why
    L2/charts/go-service ships `networkPolicy.enabled: false` by default: the
    rules are written down there, and an env with this set to true is the kind
    that can turn them on.
  EOT
  type        = bool
  default     = true
}
