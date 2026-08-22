terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Remote state as a partial configuration — see L0/aws/versions.tf for why
  # the block is declared rather than commented out.
  #
  #   cp backend.hcl.example backend.hcl     # then edit
  #   tofu init -backend-config=backend.hcl  # `just cloud up gcp` does this for you
  #
  # GCS has server-side locking built in, so there is no lock table to create.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate)
}
