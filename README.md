# k8s-snapshots-audit

This script runs daily to create an audit report of the state of PV snapshots for our GKE clusters, and is intended
to be a companion to the utility which actually schedules the snapshots, which is called
[k8s-snapshots](https://github.com/farmersedgeinc/k8s-snapshots).

In short, the `k8s-snapshots` will create daily snapshots of all PVs which have a "backup schedule" annotation.
This annotation will determine how often to schedule snapshots and how long to retain these.

This audit script will, on a daily basis, check that all eligible PVs have the backup annotation so they can be 
included in the snapshot scheduling.  Some volume types are not supported by `k8s-snapshots`, such as Rook-Ceph
and NFS volumes, so these are just listed in the audit report as "unsupported".

If a supported volume does not have the backup annotation, the audit script will add the annotation `P1D P14D` which calls for
a daily snapshot, retained for 14 days.  See the [ISO 8601 durations](https://en.wikipedia.org/wiki/ISO_8601#Durations) for further details.

The audit report PDF is uploaded to the `#k8s_snapshotter` Slack Channel.  This report will list all of the PVCs by namespace, and list
how many snapshots each has, along with the create date of the oldest and newest snapshots.  If the newest of the daily snapshots is more than a
couple of days old, it is highlighted in red for further investigation.

## Required components for the audit script:

1. ENV variables, found in `project_configs/projects/k8s-snapshotter-audit`
1. Google Service Account, created in `terraform2`, and kept in the helm chart envs.
1. Slack Application and Webhook (details in the helm chart envs).

**Cheers!**
