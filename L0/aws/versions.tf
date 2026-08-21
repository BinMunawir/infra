terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
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

  # Remote state, as a PARTIAL configuration: the block is declared here so
  # OpenTofu always uses the S3 backend, and the bucket/key/region come from a
  # file at init time.
  #
  #   cp backend.hcl.example backend.hcl     # then edit
  #   tofu init -backend-config=backend.hcl  # `just aws-up` does this for you
  #
  # Declared rather than commented out on purpose. A commented backend means
  # `tofu init` silently succeeds against local state and the mistake is only
  # visible later, in an incident; an empty block fails loudly until it is
  # configured. A fintech cluster whose state lives on one laptop is both a
  # single point of failure and an audit finding.
  #
  # backend.hcl is gitignored — it names a bucket and an account.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "maal"
      Layer     = "L0"
      ManagedBy = "opentofu"
      Env       = var.env
    }
  }
}

# Configured from the cluster this module creates. See the note in main.tf about
# the two-phase apply this implies.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
