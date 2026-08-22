# L0/aws — EKS implementation of the L0 contract.
#
# STATUS: unvalidated skeleton. The shape is right and the outputs are the
# contract; the resource details have not been applied against a real account.
# `just check tofu` validates it; `just cloud up aws` would apply it.
#
# TWO-PHASE APPLY: the `kubernetes` provider in versions.tf is configured from
# module.eks outputs, so a cold `tofu apply` on an empty state cannot plan the
# StorageClass resource. Either apply in two passes:
#     tofu apply -target=module.vpc -target=module.eks && tofu apply
# or move the StorageClass into L1 and drop `storageClass` to a plain string
# output. The former keeps the contract honest (L0 owns storage), so that is
# what this module does.

locals {
  name = "${var.cluster_name}-${var.env}"

  # The name L1/L2 will put in every PVC. Created below, not assumed.
  storage_class = "gp3"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = local.name
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway = true
  single_nat_gateway = var.env != "prod" # one NAT is cheaper; prod gets one per AZ

  # Required so the AWS load balancer controller can discover subnets.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint so an operator laptop can reach it. Restrict or go fully
  # private before this holds anything real.
  cluster_endpoint_public_access = true

  # This is what makes IRSA work. L1 does not read it today (the contract has
  # three outputs, not four) but anything reaching an AWS API will need it.
  enable_irsa = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    eks-pod-identity-agent = {}
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = tostring(var.enable_network_policy)
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_count
      max_size       = var.node_count * 3
      desired_size   = var.node_count
    }
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.47"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ─── the storageClass contract output ──────────────────────────────────────
# EKS ships a `gp2` default with Immediate binding, which violates the contract:
# `just verify l0` asserts volumeBindingMode=WaitForFirstConsumer, and L0/local/
# up.sh refuses to publish a contract without it. Create a compliant gp3 class
# and make it the default.

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = local.storage_class
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer" # contract requirement
  allow_volume_expansion = true                   # contract requirement
  reclaim_policy         = "Retain"               # a deleted PVC must not delete ledger data

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
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
        server                     = module.eks.cluster_endpoint
        certificate-authority-data = module.eks.cluster_certificate_authority_data
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
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "aws"
          args       = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
        }
      }
    }]
  })
}
