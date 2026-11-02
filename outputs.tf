output "capacity_provider_name" {
  description = "Name to put in a service's capacity provider strategy, and in the cluster's capacity provider list."
  value       = aws_ecs_capacity_provider.this.name
}

output "capacity_provider_arn" {
  description = "ARN of the capacity provider."
  value       = aws_ecs_capacity_provider.this.arn
}

output "autoscaling_group_name" {
  description = "Name of the instance group. Its desired count is ECS's to move, not yours."
  value       = aws_autoscaling_group.this.name
}

output "autoscaling_group_arn" {
  description = "ARN of the instance group."
  value       = aws_autoscaling_group.this.arn
}

output "instance_role_name" {
  description = "Instance role name, for attaching a policy the workload needs on the host."
  value       = aws_iam_role.instance.name
}

output "instance_role_arn" {
  description = "Instance role ARN."
  value       = aws_iam_role.instance.arn
}

output "instance_security_group_id" {
  description = "The security group this module made, or null when security_group_ids was given."
  value       = one(aws_security_group.instance[*].id)
}

output "ami_id" {
  description = "AMI the launch template resolved, so a plan shows which image a new instance boots."
  value       = data.aws_ssm_parameter.ecs_ami.value
}
