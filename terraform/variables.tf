variable addons {
  type = list(object({
    name    = string
    version = string
  }))

  default = [
    # {
    #   name    = "kube-proxy"
    #   version = "v1.21.2-eksbuild.2"
    # },
    # {
    #   name    = "vpc-cni"
    #   version = "v1.10.1-eksbuild.1"
    # },
    # {
    #   name    = "coredns"
    #   version = "v1.8.4-eksbuild.1"
    # },
    {
      name    = "aws-ebs-csi-driver"
      version = "v1.26.1"
    },
    # {
    #   name    = "aws-efs-csi-driver"
    #   version = "v1.26.1"
    # },
  ]
}
