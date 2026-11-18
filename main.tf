# An ECS capacity provider whose instance group has a minimum of 0.
#
# Fargate cannot do GPUs, large local disks, or anything else that needs a real
# instance. Moving a service to EC2 normally means paying for an instance whose only
# job is to wait. This module removes the waiting: the group's minimum is 0, ECS
# managed scaling starts an instance when a task has nowhere to run, and removes it
# once the task stops.
#
# What it does not do, on purpose: decide when the task should exist. That is the
# service's own scaling, and it belongs with whatever owns the service. See the README
# on choosing that signal, because the obvious choice is usually wrong.

data "aws_partition" "current" {}

locals {
  # The GPU variant of the AMI carries the NVIDIA driver and the container runtime
  # hook. A standard image boots and never exposes the GPU to a task.
  ami_variant   = var.gpu ? "gpu" : "amd64"
  ami_parameter = "/aws/service/ecs/optimized-ami/${var.ami_family}/${local.ami_variant}/recommended/image_id"
  partition     = data.aws_partition.current.partition
}

data "aws_ssm_parameter" "ecs_ami" {
  name = coalesce(var.ami_ssm_parameter, local.ami_parameter)
}

# --- Instance role ----------------------------------------------------------

# The ECS agent registers the instance with the cluster and reports task state. This
# is the instance's role; tasks keep their own task roles.
resource "aws_iam_role" "instance" {
  name_prefix = "${var.name}-inst-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Session Manager instead of SSH. The group takes no key pair and the security group
# has no ingress, so this is the only way onto an instance.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  count      = var.enable_session_manager ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "instance_extra" {
  for_each   = toset(var.additional_instance_policy_arns)
  role       = aws_iam_role.instance.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "${var.name}-inst-"
  role        = aws_iam_role.instance.name
  tags        = var.tags
}

# --- Network ----------------------------------------------------------------

# With awsvpc networking the task has its own ENI and its own security group, so this
# group is the instance: it pulls images and reaches the ECS and SSM endpoints. Nothing
# connects in, which is why there is no ingress rule here at all.
resource "aws_security_group" "instance" {
  count       = var.security_group_ids == null ? 1 : 0
  name_prefix = "${var.name}-inst-"
  description = "ECS scale-to-zero instances: ${var.name}"
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "instance_out" {
  count             = var.security_group_ids == null ? 1 : 0
  security_group_id = aws_security_group.instance[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Image pulls, ECS agent, SSM"
}

# --- Instances --------------------------------------------------------------

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = coalesce(var.security_group_ids, [one(aws_security_group.instance[*].id)])

  block_device_mappings {
    device_name = var.root_device_name
    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  # The agent reads the cluster name from here. Without it the instance boots, never
  # joins, and ECS keeps asking for capacity that is already running and idle.
  user_data = base64encode(join("\n", concat(
    ["#!/bin/bash", "echo \"ECS_CLUSTER=${var.cluster_name}\" >> /etc/ecs/ecs.config"],
    var.gpu ? ["echo \"ECS_ENABLE_GPU_SUPPORT=true\" >> /etc/ecs/ecs.config"] : [],
    [for k, v in var.ecs_config : "echo \"${k}=${v}\" >> /etc/ecs/ecs.config"],
    var.extra_user_data == null ? [] : [var.extra_user_data],
  )))

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = var.detailed_monitoring
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = var.name })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name_prefix = "${var.name}-"

  # Zero is the whole point. ECS managed scaling owns the desired count from here on,
  # so changes to it are ignored rather than fought on every apply.
  min_size         = 0
  max_size         = var.max_size
  desired_capacity = 0

  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  # Managed termination protection needs two things on the group: new instances
  # protected from scale-in, and the AmazonECSManaged tag. Without the protection
  # AWS rejects the capacity provider at create time. ECS lifts the protection from
  # an instance once it runs no tasks, so the group can still scale in to zero.
  protect_from_scale_in = var.managed_termination_protection

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = var.name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# --- Capacity provider ------------------------------------------------------

resource "aws_ecs_capacity_provider" "this" {
  name = var.name

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.this.arn

    managed_termination_protection = var.managed_termination_protection ? "ENABLED" : "DISABLED"
    managed_draining               = var.managed_draining ? "ENABLED" : "DISABLED"

    managed_scaling {
      status = "ENABLED"
      # 100 means capacity tracks tasks exactly. Lower leaves a spare instance
      # running, which is the cost this module exists to remove.
      target_capacity           = var.target_capacity
      minimum_scaling_step_size = var.minimum_scaling_step_size
      maximum_scaling_step_size = var.maximum_scaling_step_size
      instance_warmup_period    = var.instance_warmup_seconds
    }
  }

  tags = var.tags
}
