variable "name" {
  description = "Name for the capacity provider and a prefix for the group, launch template, role and security group."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster the instances join. Written into /etc/ecs/ecs.config as ECS_CLUSTER."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the instance security group. Not needed when security_group_ids is given."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Subnets the group launches into. Private ones, with a route out for image pulls."
  type        = list(string)
}

variable "instance_type" {
  description = "Instance type. g4dn.xlarge is one NVIDIA T4 with 4 vCPU and 16 GB."
  type        = string
}

variable "gpu" {
  description = "Use the GPU variant of the ECS-optimized AMI and set ECS_ENABLE_GPU_SUPPORT. The standard image boots on a GPU instance and never exposes the GPU to a task."
  type        = bool
  default     = false
}

variable "ami_family" {
  description = "ECS-optimized AMI family, as it appears in the SSM parameter path."
  type        = string
  default     = "amazon-linux-2023"
}

variable "ami_ssm_parameter" {
  description = "Full SSM parameter path for the AMI, when the family and gpu flag do not describe the image you want."
  type        = string
  default     = null
}

variable "max_size" {
  description = "Most instances at once. One task per instance with target_capacity 100, so this is also the task ceiling."
  type        = number
  default     = 1
}

variable "root_volume_gb" {
  description = "Root volume size. A large container image needs room to unpack: a 6 GB image does not fit the default."
  type        = number
  default     = 60
}

variable "root_device_name" {
  description = "Root device name for the chosen AMI family."
  type        = string
  default     = "/dev/xvda"
}

variable "kms_key_arn" {
  description = "Key for the root volume. Null uses the account's EBS default."
  type        = string
  default     = null
}

variable "security_group_ids" {
  description = "Security groups for the instances. Null creates one with egress only and no ingress, which is what an awsvpc task needs."
  type        = list(string)
  default     = null
}

variable "target_capacity" {
  description = "Managed scaling target, as a percentage. 100 tracks tasks exactly; lower keeps spare capacity running."
  type        = number
  default     = 100

  validation {
    condition     = var.target_capacity > 0 && var.target_capacity <= 100
    error_message = "target_capacity is a percentage between 1 and 100."
  }
}

variable "minimum_scaling_step_size" {
  description = "Fewest instances ECS adds or removes at a time."
  type        = number
  default     = 1
}

variable "maximum_scaling_step_size" {
  description = "Most instances ECS adds or removes at a time."
  type        = number
  default     = 1
}

variable "instance_warmup_seconds" {
  description = "How long ECS waits before counting a new instance in its scaling maths. Set it to the measured boot-and-pull time, so a slow first start does not make ECS ask for a second instance."
  type        = number
  default     = 300
}

variable "managed_termination_protection" {
  description = "Let ECS protect an instance while a task runs on it, so a scale-in cannot stop work in progress. Needs the AmazonECSManaged tag, which this module sets."
  type        = bool
  default     = true
}

variable "managed_draining" {
  description = "Let ECS drain an instance before termination."
  type        = bool
  default     = true
}

variable "enable_session_manager" {
  description = "Attach AmazonSSMManagedInstanceCore. The group has no key pair and the security group no ingress, so this is the only way onto an instance."
  type        = bool
  default     = true
}

variable "additional_instance_policy_arns" {
  description = "More managed policies for the instance role."
  type        = list(string)
  default     = []
}

variable "ecs_config" {
  description = "Extra lines for /etc/ecs/ecs.config, as key to value."
  type        = map(string)
  default     = {}
}

variable "extra_user_data" {
  description = "Shell appended to the generated user data, after the ecs.config lines."
  type        = string
  default     = null
}

variable "detailed_monitoring" {
  description = "One-minute CloudWatch metrics on the instances."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for every resource this module creates."
  type        = map(string)
  default     = {}
}
