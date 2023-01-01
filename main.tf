data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  cidr = var.vpc_cidr_block

  azs             = data.aws_availability_zones.available.names
  private_subnets = slice(var.private_subnet_cidr_blocks, 0, var.private_subnets_per_vpc)
  public_subnets  = slice(var.public_subnet_cidr_blocks, 0, var.public_subnets_per_vpc)

  enable_nat_gateway = true
  enable_vpn_gateway = true

  map_public_ip_on_launch = true
}

module "app_security_group" {
  source = "terraform-aws-modules/security-group/aws//modules/web"

  name        = "web-server-sg-${var.project_name}-${var.environment}"
  description = "Security group for web-server with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.public_subnets_cidr_blocks
}

module "lb_security_group" {
  source = "terraform-aws-modules/security-group/aws//modules/web"

  name        = "load-balancer-sg-${var.project_name}-${var.environment}"
  description = "Security group for load-balancer with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
}

module "elb_http" {
  source  = "terraform-aws-modules/elb/aws"
  version = "~> 2.0"

  name = "elb-example-for-count"

  subnets             = module.vpc.public_subnets
  security_groups     = [module.lb_security_group.security_group_id]
  internal            = false
  number_of_instances = length(aws_instance.app)
  instances           = aws_instance.app.*.id
  listener = [
    # {
    #   instance_port     = 80
    #   instance_protocol = "HTTP"
    #   lb_port           = 80
    #   lb_protocol       = "HTTP"
    # },
    {
      instance_port     = 22
      instance_protocol = "TCP"
      lb_port           = 22
      lb_protocol       = "TCP"
    }
  ]
  health_check = {
    target              = "HTTP:80/index.html"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_key_pair" "key-tf" {
  key_name   = "key-tf-new"
  public_key = file("${path.module}/id_rsa.pub")
}

resource "aws_instance" "app" {
  depends_on = [module.vpc]

  count = var.instances_per_subnet * length(module.vpc.public_subnets)

  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.key-tf.key_name
  subnet_id              = module.vpc.public_subnets[count.index % length(module.vpc.public_subnets)]
  vpc_security_group_ids = [module.app_security_group.security_group_id]
  tags = {
    Name        = "my-machine-${count.index}"
    Terraform   = "true"
    Project     = var.project_name
    Environment = var.environment
  }
}
