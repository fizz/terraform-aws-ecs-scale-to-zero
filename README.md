# terraform-aws-ecs-scale-to-zero

An ECS capacity provider whose instance group has a minimum of **0**.

Fargate cannot give you a GPU, a large local disk, or an instance store. Moving a service to EC2 normally means paying for a host whose only job is to wait. This module removes the waiting: the group's minimum is 0, ECS managed scaling starts an instance when a task has nowhere to run, and removes it once the task stops.

```hcl
module "docling_gpu" {
  source = "github.com/fizz/terraform-aws-ecs-scale-to-zero?ref=<commit SHA>"

  name          = "docling-gpu-dev"
  cluster_name  = aws_ecs_cluster.this.name
  vpc_id        = var.vpc_id
  subnet_ids    = var.private_subnet_ids
  instance_type = "g4dn.xlarge"
  gpu           = true

  root_volume_gb          = 60   # the image is about 6 GB
  instance_warmup_seconds = 300  # set to the boot-and-pull time you measure
}
```

Then add it to the cluster and point the service at it:

```hcl
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", module.docling_gpu.capacity_provider_name]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}
```

Pin to a commit SHA, not a branch or a tag that can move.

## What this module does not decide

**When the task should exist.** This module supplies capacity for a task that ECS wants to place; it never decides that a task is wanted. That is the service's own scaling, and it stays with whatever owns the service.

That division matters because the obvious signal is usually wrong, and getting it wrong is worse than not scaling at all.

### Choosing the signal

A queue-depth metric looks like the right trigger and is a trap. **Queue depth reads zero while the work runs.** A worker claims an item within a second, so a rule that scales on depth alone starts the host late or never, and scales in while the work is still going — taking the instance out from under the job it was started for.

Scale on **queued or running above zero**, and scale in only once **both have been zero** for several minutes. If more than one producer writes the metric, read the `Maximum` rather than the average, or a rolling deploy halves your signal.

The alternative is task scale-in protection: let the task protect itself while it holds work, through the ECS agent's task-protection endpoint, and scale in freely. That keeps hosts busy but also holds deploys until the work finishes, so the deploy's wait has to allow for it.

## Traps this module handles for you

| Trap | What happens without it |
|---|---|
| **The `AmazonECSManaged` tag** | Managed termination protection is set through this tag on the group. Without the tag the capacity provider is created and silently protects nothing, so a scale-in can stop an instance while its task is working. |
| **The GPU AMI variant** | A standard ECS-optimized image boots fine on a GPU instance and never exposes the GPU to a task. The GPU variant carries the driver and the container runtime hook, and `ECS_ENABLE_GPU_SUPPORT` has to be in `ecs.config`. |
| **`ECS_CLUSTER` in user data** | Without it the instance boots, never joins the cluster, and ECS keeps asking for capacity that is already running and idle. |
| **Root volume size** | The default root volume does not fit a large image with room to unpack it. A CUDA image is several gigabytes. |
| **`desired_capacity` drift** | ECS owns the desired count once managed scaling is on. The group ignores changes to it rather than fighting ECS on every apply. |
| **`instance_warmup_period`** | Too short and ECS asks for a second instance while the first is still pulling its image. Set it to the time you measure, not a guess. |

## Measuring the first start

The first task after an idle period waits for an instance to boot and pull the image. Measure it on a non-production environment before relying on it, because every timeout downstream is derived from that number: the client's retry budget, `instance_warmup_seconds`, and any health-check grace period.

Also check how long your service discovery caches a negative answer. If the name is remembered as having no address, a caller keeps hearing "no such name" after the task is up, and that time comes out of the caller's retry budget.

## Inputs

See `variables.tf`. The ones worth setting on day one are `instance_type`, `gpu`, `root_volume_gb`, `max_size` and `instance_warmup_seconds`.

## Outputs

`capacity_provider_name` is the one you need; the rest are there for attaching a policy to the instance role or reading which AMI a plan resolved.

## Licence

MIT.
