# The first five variables are byte-identical to L0/aws/variables.tf. That
# shared surface is the swap point — if these two files drift, the layer has
# stopped being portable.

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

# ─── GCP-specific ──────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "GCP region. Regional cluster — control plane replicated across zones."
  type        = string
  default     = "me-central2" # Dammam
}

variable "subnet_cidr" {
  description = "Primary CIDR for the cluster subnet."
  type        = string
  default     = "10.30.0.0/16"
}

variable "node_machine_type" {
  description = "Worker machine type. Sized for Argo + Istio + cert-manager + External Secrets."
  type        = string
  default     = "e2-standard-2"
}

variable "enable_network_policy" {
  description = <<-EOT
    Enable Dataplane V2 (Cilium-backed), which genuinely enforces NetworkPolicy
    — unlike kindnet locally. See the asymmetry list in ../contract.md.
  EOT
  type        = bool
  default     = true
}
