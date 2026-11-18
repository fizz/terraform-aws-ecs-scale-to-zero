# --- Fast scale-in ----------------------------------------------------------
#
#   EventBridge rule (task STOPPED on this capacity provider)
#     -> SSM Automation, aws:executeScript (fast_scale_in.py)
#        drains each empty instance, checks it again, lifts protection, terminates it
#
# ECS managed scaling scales in through a target-tracking alarm that needs 15 one-minute
# datapoints below target. AWS owns that alarm and the policy rewrites any edit, so an
# idle instance runs for about 15 minutes after its last task, at the full hourly price.
# This removes it when the last task stops instead. Managed scaling still owns
# scale-out, and its own scale-in stays as the fallback. Each run leaves an Automation
# execution record with the script's output.

locals {
  fast_scale_in      = var.fast_scale_in ? 1 : 0
  fast_scale_in_name = "${var.name}-fast-scale-in"
  account_id         = data.aws_caller_identity.current.account_id
  # The region comes from the document ARN below, so this module reads no region
  # attribute, whose name differs across AWS provider major versions.
  cluster_arn_any_region = "arn:${local.partition}:ecs:*:${local.account_id}:cluster/${var.cluster_name}"
}

# The role the runbook runs as.
resource "aws_iam_role" "fast_scale_in_automation" {
  count       = local.fast_scale_in
  name_prefix = "${var.name}-fsi-run-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "fast_scale_in_automation" {
  count = local.fast_scale_in
  name  = "fast-scale-in"
  role  = aws_iam_role.fast_scale_in_automation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListInCluster"
        Effect   = "Allow"
        Action   = ["ecs:ListContainerInstances", "ecs:ListTasks"]
        Resource = [local.cluster_arn_any_region, "arn:${local.partition}:ecs:*:${local.account_id}:container-instance/${var.cluster_name}/*"]
      },
      {
        Sid    = "ReadAndDrainInCluster"
        Effect = "Allow"
        Action = [
          "ecs:DescribeContainerInstances",
          "ecs:DescribeTasks",
          "ecs:UpdateContainerInstancesState",
        ]
        Resource  = "*"
        Condition = { ArnLike = { "ecs:cluster" = local.cluster_arn_any_region } }
      },
      {
        # Only this group's instances, and only to lift protection and remove them.
        Sid      = "RemoveFromGroup"
        Effect   = "Allow"
        Action   = ["autoscaling:SetInstanceProtection", "autoscaling:TerminateInstanceInAutoScalingGroup"]
        Resource = aws_autoscaling_group.this.arn
      },
    ]
  })
}

resource "aws_ssm_document" "fast_scale_in" {
  count           = local.fast_scale_in
  name            = local.fast_scale_in_name
  document_type   = "Automation"
  document_format = "JSON"
  tags            = var.tags

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Removes empty ${var.name} instances when their last task stops, instead of 15 minutes later."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      AutomationAssumeRole = {
        type    = "String"
        default = aws_iam_role.fast_scale_in_automation[0].arn
      }
      DryRun = {
        type          = "String"
        default       = tostring(var.fast_scale_in_dry_run)
        allowedValues = ["true", "false"]
      }
    }
    mainSteps = [{
      name = "RemoveEmptyInstances"
      # Can wait up to a minute for the task count to catch up with the stop event.
      action         = "aws:executeScript"
      timeoutSeconds = 180
      inputs = {
        Runtime = "python3.11"
        Handler = "handler"
        Script  = file("${path.module}/fast_scale_in.py")
        InputPayload = {
          ClusterName          = var.cluster_name
          CapacityProviderName = aws_ecs_capacity_provider.this.name
          AutoScalingGroupName = aws_autoscaling_group.this.name
          DryRun               = "{{ DryRun }}"
        }
      }
      outputs = [
        { Name = "Removed", Selector = "$.Payload.Removed", Type = "String" },
        { Name = "Log", Selector = "$.Payload.Log", Type = "String" },
      ]
    }]
  })
}

# The role EventBridge uses to start the runbook.
resource "aws_iam_role" "fast_scale_in_trigger" {
  count       = local.fast_scale_in
  name_prefix = "${var.name}-fsi-evt-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "fast_scale_in_trigger" {
  count = local.fast_scale_in
  name  = "start-automation"
  role  = aws_iam_role.fast_scale_in_trigger[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        # Scoping to the document fails at runtime with AccessDenied naming the document
        # ARN, even when that exact ARN is granted. Region and account is the narrowest
        # scope that works; PassRole below limits what a started runbook can do.
        Resource = "${join(":", slice(split(":", aws_ssm_document.fast_scale_in[0].arn), 0, 5))}:*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.fast_scale_in_automation[0].arn
      },
    ]
  })
}

# Every task on this capacity provider that stops, in this cluster.
resource "aws_cloudwatch_event_rule" "fast_scale_in" {
  count       = local.fast_scale_in
  name        = local.fast_scale_in_name
  description = "Task stopped on capacity provider ${var.name}"

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn           = [{ suffix = ":${local.account_id}:cluster/${var.cluster_name}" }]
      capacityProviderName = [aws_ecs_capacity_provider.this.name]
      lastStatus           = ["STOPPED"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "fast_scale_in" {
  count = local.fast_scale_in
  rule  = aws_cloudwatch_event_rule.fast_scale_in[0].name
  # Pinned to the exact version this apply wrote, never $DEFAULT or $LATEST: the target
  # runs the script that is in this commit. A content change makes a new version, and the
  # same apply moves the target to it.
  arn      = "${replace(aws_ssm_document.fast_scale_in[0].arn, ":document/", ":automation-definition/")}:${aws_ssm_document.fast_scale_in[0].latest_version}"
  role_arn = aws_iam_role.fast_scale_in_trigger[0].arn
}
