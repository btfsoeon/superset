################
#  Providers   #
################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
        source = "hashicorp/helm"
        version = "~>2.0.0"
    }
  }
}

# Configure AWS Provider
provider "aws" {
  region = "us-west-2"
}

data "aws_caller_identity" "current" {}


################
#     VPC      #
################

# Create VPC
module "vpc" {
    source = "terraform-aws-modules/vpc/aws"
    version = "5.0.0"

    name = "superset-vpc"

    cidr = "10.0.0.0/16"

    azs = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
    public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

    enable_nat_gateway   = true
    single_nat_gateway   = true
    enable_dns_hostnames = true

    tags = {
        Terraform = "true"
        Environment = "dev"
    }
}

################
#  EKS MODULE  #
################

# Deploy EKS
module "eks" {
    source = "terraform-aws-modules/eks/aws"
    version = "19.21.0"

    cluster_name = "superset-cluster"
    cluster_version = "1.27"

    vpc_id = module.vpc.vpc_id
    subnet_ids = module.vpc.private_subnets
    cluster_endpoint_public_access = true

    eks_managed_node_group_defaults = {
        ami_type = "AL2_x86_64"
    }

    eks_managed_node_groups = {
        one = {
            name = "node-group-1"

            instance_types = ["t3.medium"]

            min_size = 1
            max_size = 3
            desired_size = 2
        }

        two = {
            name = "node-group-2"

            instance_types = ["t3.medium"]

            min_size = 1
            max_size = 2
            desired_size = 2
        }
    }
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

# Add Addons
module ebs-csi-driver-role {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "ebs_csi_driver"
  attach_ebs_csi_policy = true
  allow_self_assume_role = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "addons" {
  for_each          = { for addon in var.addons : addon.name => addon }
  cluster_name      = module.eks.cluster_name
  addon_name        = each.value.name
  # addon_version     = each.value.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn = module.ebs-csi-driver-role.iam_role_arn
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# Configure Helm
provider "helm" {
    kubernetes {
        host                   = data.aws_eks_cluster.cluster.endpoint
        cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
        token                  = data.aws_eks_cluster_auth.cluster.token
    }
}

# Set up eks alb https://andrewtarry.com/posts/terraform-eks-alb-setup/
module "lb_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "superset_eks_lb"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "service-account" {
  metadata {
    name = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
        "app.kubernetes.io/name"= "aws-load-balancer-controller"
        "app.kubernetes.io/component"= "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = module.lb_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "lb" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  depends_on = [
    kubernetes_service_account.service-account
  ]

  set {
    name  = "region"
    value = "us-west-2"
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon/aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
}

# resource "kubernetes_ingress_v1" "ingress" {
#   wait_for_load_balancer = true
#   metadata {
#     name = "ingress-service"
#     annotations = {
#       "kubernetes.io/ingress.class" = "alb"
#     }
#   }

#   spec {
#     rule {
#       http {
#         path {
#           path = "/*"
#           backend {
#             service {
#               name = "my-superset"
#               port {
#                 number = 8088
#               }
#             }
#           }
#         }
#       }
#     }

#     # tls {
#     #   secret_name = "tls-secret"
#     # }
#   }
# }

# # Display load balancer hostname (typically present in AWS)
# output "load_balancer_hostname" {
#   value = kubernetes_ingress_v1.ingress.status.0.load_balancer.0.ingress.0.hostname
# }

# # Display load balancer IP (typically present in GCP, or using Nginx ingress controller)
# output "load_balancer_ip" {
#   value = kubernetes_ingress_v1.ingress.status.0.load_balancer.0.ingress.0.ip
# }

################
#   Superset   #
################

# Separate namespace
module "superset_namespace" {
  source = "git::https://github.com/gruntwork-io/terraform-kubernetes-namespace.git//modules/namespace?ref=v0.1.0"
  name = "superset"
}

# Deploy Superset
resource "helm_release" "superset" {
  name              = "my-superset"
  repository        = "https://apache.github.io/superset"
  chart             = "superset"
  version           = "0.10.9"
  namespace         = module.superset_namespace.name
  depends_on = [
    module.superset_namespace,
    resource.aws_eks_addon.addons,
  ]
  reuse_values      = true
  force_update      = true
  recreate_pods     = true

  values = [
    file("../helm/superset/values.yaml")
  ]
}

#TODO extract variables
#TODO output service name
