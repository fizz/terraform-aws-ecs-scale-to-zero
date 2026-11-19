"""Remove an empty instance from a scale-to-zero group as soon as its last task stops.

Runs as the aws:executeScript step of an SSM Automation runbook, started by an
EventBridge rule on each task stop for the capacity provider.

ECS managed scaling scales in through a target-tracking alarm that needs 15 one-minute
datapoints below target, so an idle instance runs for about 15 minutes after its last
task. This script removes empty instances at once. Managed scaling stays in charge of
scale-out, and its own scale-in is still the fallback if this script fails.

An instance is removed only when all of these hold:
  - no task for this capacity provider waits for a place to run,
  - the instance registered more than MIN_AGE_SECONDS ago,
  - it runs no tasks and has no pending tasks, checked again after draining it.
Draining before the second check stops ECS placing a task on the instance between the
check and the termination.

Two runs can start close together. That is safe: the second finds the instance
draining or gone, and a failed terminate is not an error here.
"""

import datetime
import time

import boto3
from botocore.exceptions import ClientError

# A new instance registers before ECS places its task. The waiting-task check covers
# that gap; the age check covers the case where ECS has not yet listed the task.
MIN_AGE_SECONDS = 60
# The task-stop event can arrive before the instance's running count drops.
ATTEMPTS = 6
ATTEMPT_INTERVAL_SECONDS = 10


class FastScaleIn:
    def __init__(self, cluster, capacity_provider, group, dry_run):
        self.cluster = cluster
        self.capacity_provider = capacity_provider
        self.group = group
        self.dry_run = dry_run
        self.ecs = boto3.client("ecs")
        self.autoscaling = boto3.client("autoscaling")
        self.log = []

    def note(self, message):
        print(message)
        self.log.append(message)

    def tasks_waiting_for_capacity(self):
        """True when a task for this capacity provider has not started yet."""
        paginator = self.ecs.get_paginator("list_tasks")
        for page in paginator.paginate(cluster=self.cluster, desiredStatus="RUNNING"):
            task_arns = page["taskArns"]
            if not task_arns:
                continue
            tasks = self.ecs.describe_tasks(cluster=self.cluster, tasks=task_arns)["tasks"]
            for task in tasks:
                if task.get("capacityProviderName") != self.capacity_provider:
                    continue
                if task["lastStatus"] in ("PROVISIONING", "PENDING", "ACTIVATING"):
                    return True
        return False

    def provider_instances(self):
        """Container instances of this capacity provider, ACTIVE or DRAINING."""
        instances = []
        paginator = self.ecs.get_paginator("list_container_instances")
        for page in paginator.paginate(cluster=self.cluster):
            instance_arns = page["containerInstanceArns"]
            if not instance_arns:
                continue
            described = self.ecs.describe_container_instances(
                cluster=self.cluster, containerInstances=instance_arns
            )["containerInstances"]
            instances.extend(
                instance
                for instance in described
                if instance.get("capacityProviderName") == self.capacity_provider
                and instance["status"] in ("ACTIVE", "DRAINING")
            )
        return instances

    @staticmethod
    def is_empty(instance):
        return instance["runningTasksCount"] == 0 and instance["pendingTasksCount"] == 0

    @staticmethod
    def old_enough(instance):
        age = datetime.datetime.now(datetime.timezone.utc) - instance["registeredAt"]
        return age.total_seconds() >= MIN_AGE_SECONDS

    def describe_one(self, container_instance_arn):
        return self.ecs.describe_container_instances(
            cluster=self.cluster, containerInstances=[container_instance_arn]
        )["containerInstances"][0]

    def set_state(self, container_instance_arn, status):
        self.ecs.update_container_instances_state(
            cluster=self.cluster, containerInstances=[container_instance_arn], status=status
        )

    def remove(self, instance):
        container_instance_arn = instance["containerInstanceArn"]
        ec2_instance_id = instance["ec2InstanceId"]

        if self.dry_run:
            self.note(f"dry run: would drain and terminate {ec2_instance_id}")
            return True

        self.set_state(container_instance_arn, "DRAINING")
        if not self.is_empty(self.describe_one(container_instance_arn)):
            self.note(f"{ec2_instance_id} took a task while draining; returned it to ACTIVE")
            self.set_state(container_instance_arn, "ACTIVE")
            return False

        try:
            self.autoscaling.set_instance_protection(
                AutoScalingGroupName=self.group,
                InstanceIds=[ec2_instance_id],
                ProtectedFromScaleIn=False,
            )
            self.autoscaling.terminate_instance_in_auto_scaling_group(
                InstanceId=ec2_instance_id, ShouldDecrementDesiredCapacity=True
            )
        except ClientError as error:
            # An instance that is already leaving the group is not an error here.
            self.note(f"could not remove {ec2_instance_id}: {error}")
            return False

        self.note(f"removed empty instance {ec2_instance_id} from {self.group}")
        return True

    def run(self):
        for attempt in range(1, ATTEMPTS + 1):
            if self.tasks_waiting_for_capacity():
                self.note("a task waits for capacity; left the group alone")
                return []

            instances = self.provider_instances()
            candidates = [i for i in instances if self.is_empty(i) and self.old_enough(i)]
            busy = [i for i in instances if not self.is_empty(i)]

            if candidates:
                return [i["ec2InstanceId"] for i in candidates if self.remove(i)]

            # Nothing empty yet. If an instance still reports a task, the stop that
            # started this run can be still on its way to the count; look again.
            if not busy or attempt == ATTEMPTS:
                break
            time.sleep(ATTEMPT_INTERVAL_SECONDS)

        self.note("no empty instance to remove")
        return []


def handler(events, context):
    job = FastScaleIn(
        cluster=events["ClusterName"],
        capacity_provider=events["CapacityProviderName"],
        group=events["AutoScalingGroupName"],
        dry_run=events.get("DryRun") == "true",
    )
    removed = job.run()
    return {"Removed": ",".join(removed), "Log": "\n".join(job.log)}
