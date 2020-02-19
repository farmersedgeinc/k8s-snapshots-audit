# k8s-snapshots-audit

This script runs daily to create an audit report of the state of PVC snapshots for our GKE clusters, and is intended
to be a companion to the utility which actually schedules the snapshots, which is called
[k8s-snapshots](https://github.com/farmersedgeinc/k8s-snapshots).

This audit can (but is not obligated to) reside in the same namespace as the `k8s-snapshots`, typically in namespace `fe-cluster`.

In short, the `k8s-snapshots` will at create daily snapshots of all PV/PVCs which have a "backup schedule" annotation.  This 
annotation will determine how often to schedule snapshots and how long to retain these.

This audit script will, on a daily basis, check that all eligible PVCs have the backup annotation so they can be 
included in the snapshot scheduling.  Some volume types are not supported by `k8s-snapshots`, such as Ceph Rook volumes
and NFS volumes, so these are just listed in the audit report as "unsupported".

If a supported volume does not have the backup annotation, the audit utility will add the annotation `P1D P14D` which calls for
a daily snapshot, retained for 14 days.  See the [ISO 8601 durations](https://en.wikipedia.org/wiki/ISO_8601#Durations) for further details.

The audit report PDF is uploaded to the `#k8s_snapshotter` Slack Channel.  This report will list all of the PVCs by namespace, and list
how many snapshots each has, along with the create date of the oldest and newest snapshots.  If the newest of the daily snapshots is more than a
couple of days old, it is highlighted in red for further investigation.

## Required components for the audit script:

1. ENV variables, found in `project_configs/tools/k8s_snapshotter-audit`
1. Google Service Account, created in `terraform2`, and kept in the helm chart envs.
1. Slack Application and Webhook (details in the helm chart envs).

**Cheers!**
