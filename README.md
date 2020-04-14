# k8s-snapshots-audit

The first component is the "scheduler", which will verify that gcp disks which back the gke persistent volumes have a snapshot schedule
assigned to the disk. The kubernetes persistent volumes must be "bound" to a persistent volume claim. The default "dailykeep14" snapshot
schedule is applied to those disks. If a disk already has a different snapshot schedule assigned to the disk, no changes are done.

Here is an example of how the snapshot schedule was created on gcp:

```
gcloud compute resource-policies create snapshot-schedule dailykeep14 \
--description "Daily snapshot at 7am UTC, keep 14 days" \
--max-retention-days 14 \
--start-time 7:00 \
--daily-schedule \
--on-source-disk-delete apply-retention-policy \
--snapshot-labels audit=fe-devops \
--region us-central1 \
--storage-location us-central1
```

The second component is the "audit". The audit report PDF is uploaded to the #k8s_snapshotter Slack Channel. This report will list all
of the PVCs by namespace, and list how many snapshots each has, along with the create date of the oldest and newest snapshots.
If the newest of the daily snapshots is more than a couple of days old, it is highlighted in red for further investigation.
Some volume types which are not supported are Rook-Ceph and NFS volumes, so these are just listed in the audit report as "unsupported".
Persistent volumes which are not bound to any claim are not included in the report.

Note, there is a utility to create snapshots [here](https://github.com/farmersedgeinc/k8s-snapshots), but we no longer use it as
it seems to have issues when managing more than 50 or so persistent volumes.

## Required components for these script:

1. ENV variables, found in `project_configs/projects/k8s-snapshotter-audit`
1. Google Service Account called `k8s_snapshotter_audit`, created in `terraform2`, with its json kept in the helm chart envs.
1. Slack Application and Webhook (details in the helm chart envs).

**Cheers!**
