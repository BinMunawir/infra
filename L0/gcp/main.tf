# L0/gcp — GKE implementation of the L0 contract.
#
# STATUS: unvalidated skeleton. Same caveats as L0/aws/main.tf, including the
# two-phase apply for the StorageClass:
#     tofu apply -target=google_container_cluster.this && tofu apply
#
# Native resources rather than a community module: a regional GKE cluster with
# one node pool is short enough that a module would hide more than it saves.
# EKS is the opposite, which is why aws/ uses terraform-aws-modules.

locals {
  name = "${var.cluster_name}-${var.env}"

  # The name L1/L2 will put in every PVC. GKE ships `standard-rwo`, but with
  # Immediate binding and Delete reclaim — both contract violations — so we
  # create our own rather than inherit it.
  storage_class = "maal-balanced"
}

resource "google_compute_network" "this" {
  name                    = local.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = local.name
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  # VPC-native cluster: pods and services get their own secondary ranges.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = cidrsubnet(var.subnet_cidr, 2, 1)
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = cidrsubnet(var.subnet_cidr, 6, 32)
  }

  private_ip_google_access = true
}

resource "google_container_cluster" "this" {
  name     = local.name
  location = var.region # regional — control plane across zones

  # GKE requires a default pool at create time; we remove it and manage our own.
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version = var.kubernetes_version

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.this.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2 gives real NetworkPolicy enforcement — the control kindnet
  # cannot provide locally.
  datapath_provider = var.enable_network_policy ? "ADVANCED_DATAPATH" : "DATAPATH_PROVIDER_UNSPECIFIED"

  # The GCP equivalent of IRSA. Not a contract output today, but L2 will want
  # it the moment anything in-cluster needs to reach a Google API.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = false # skeleton; turn this ON before prod
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.id
  location = var.region

  # node_count is per-zone on a regional cluster.
  initial_node_count = var.node_count

  autoscaling {
    min_node_count = var.node_count
    max_node_count = var.node_count * 3
  }

  node_config {
    machine_type = var.node_machine_type
    disk_type    = "pd-balanced"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ─── the storageClass contract output ──────────────────────────────────────

resource "kubernetes_storage_class_v1" "balanced" {
  metadata {
    name = local.storage_class
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "pd.csi.storage.gke.io"
  volume_binding_mode    = "WaitForFirstConsumer" # contract requirement
  allow_volume_expansion = true                   # contract requirement
  reclaim_policy         = "Retain"               # a deleted PVC must not delete ledger data

  parameters = {
    type = "pd-balanced"
  }

  depends_on = [google_container_node_pool.default]
}

# ─── the kubeconfig contract output ────────────────────────────────────────

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"

  content = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = local.name
    clusters = [{
      name = local.name
      cluster = {
        server                     = "https://${google_container_cluster.this.endpoint}"
        certificate-authority-data = google_container_cluster.this.master_auth[0].cluster_ca_certificate
      }
    }]
    contexts = [{
      name    = local.name
      context = { cluster = local.name, user = local.name }
    }]
    users = [{
      name = local.name
      user = {
        exec = {
          apiVersion         = "client.authentication.k8s.io/v1beta1"
          command            = "gke-gcloud-auth-plugin"
          provideClusterInfo = true
        }
      }
    }]
  })
}
