#!/usr/bin/ruby

# Purpose of this script is to add a snapshot schedule (aka "resourcePolicy") to the google compute physical disks which support
# the kubernetes physical volumes.  So "local" nodes disks, NFS disks, Rook disks, or anything else that does NOT have a google
# physical disk behind it will be skipped over by this script.  Also, the kubernetes persistent volume must be "bound" to a claim,
# any other persistent volume state such as "Available" will also be skipped by this script.
#
# Prerequisite for this script to run is there must already be a snapshot schedule created in your google project.  The name if this
# schedule is 'dailykeep14'.  You can always remove the "dailykeep14" snapshot schedule from your disk and assign a different custom
# schedule.  This script will NOT undo your selection of a snapshot schedule.
#
# Example of creating a snapshot schedule:
#
# gcloud compute resource-policies create snapshot-schedule dailykeep14 \
# --description "Daily snapshot at 7am UTC, keep 14 days" \
# --max-retention-days 14 \
# --start-time 7:00 \
# --daily-schedule \
# --on-source-disk-delete apply-retention-policy \
# --snapshot-labels audit=fe-devops \
# --region us-central1 \
# --storage-location us-central1
#
# Michel Remillard
# 2020 April 14

# Environmentals
cluster_name = ENV['CLUSTER_NAME']
gcloud_project = ENV['GCLOUD_PROJECT']
set_context = ENV['SET_CONTEXT']
slack_k8s_snapshotter_app_webhook = ENV['SLACK_K8S_SNAPSHOTTER_APP_WEBHOOK']

# Error Processing
def slack_notify(error_msg, webhook)
  webhook_command = %(
    curl -X POST -H "Content-type: application/json" --data "
    {
      'blocks': [
        {
          'type': 'section',
          'text': {
              'type': 'mrkdwn',
              'text': '*#{error_msg}*'
          }
        }
      ]
    }
    " #{webhook}
  )
  `#{webhook_command}`
  exit
end

# Log into google and set the project.
gcloud_auth_ok = `gcloud auth activate-service-account --key-file /service-account/k8s_snapshotter_audit_sa.json 2>&1`
slack_notify('Auth to Gcloud failed.', slack_k8s_snapshotter_app_webhook.to_s) if gcloud_auth_ok[/ERROR/]
gcloud_set_project_ok = `gcloud config set project #{gcloud_project} 2>&1`
slack_notify('Set Gcloud project failed.', slack_k8s_snapshotter_app_webhook.to_s) if gcloud_set_project_ok[/ERROR/]

# Select the kube context.
context_check = `#{set_context} 2>&1`
slack_notify('Could not set kube context.', slack_k8s_snapshotter_app_webhook.to_s) if context_check[/ERROR/]

# Get all of the physical volumes for the current context.  We only want the "Bound" volumes, not the "Available, Released, Terminating, etc." volumes.
pv_flat_list = `kubectl get pv -o=jsonpath="{.items[?(@.status.phase=='Bound')]['.metadata.name']}" 2>&1`
pv_arr = pv_flat_list.split(' ')

# For each PVC, get the "PDName".  For multi-zone disks, "gcloud" will find them within a "region", but for single-zone disks, we will have to search through each zone.
zones = ['--region us-central1', '--zone us-central1-a', '--zone us-central1-b', '--zone us-central1-c', '--zone us-central1-d', '--zone us-central1-e', '--zone us-central1-f']
pv_arr.each do |pv|
  pv_deleted = `kubectl describe persistentvolume #{pv} 2>&1`
  if pv_deleted[/NotFound/]
    # As the main loop can take a while to complete, just ensure the PV has not been deleted in the mean while.
    # Example: Error from server (NotFound): persistentvolumes "pvc-dbf41f81-2e44-11ea-b136-4201ac100008" not found
    # This is informational only, not a cause to exit the script.
    puts "This PV deleted since start of run: #{pv}."
    next
  end
  # If the PV is backed by a google disk (pdName), then we will check if the google disk has a snapshot schedule.
  pd_name = `kubectl get persistentvolume #{pv} -o=jsonpath="{['spec.gcePersistentDisk.pdName']}" 2>&1`
  if pd_name.length.positive?
    # Ok, let's try to find if there is a snapshot schedule already assigned to the disk, we might have to check several zones.
    snap_schedule = 'ERROR'
    zones.each do |zone|
      puts "Trying to find snap_schedule for #{pd_name} in #{zone}"
      snap_schedule = `gcloud compute disks describe #{pd_name} #{zone} --format="value(resourcePolicies)" 2>&1`
      break unless snap_schedule[/ERROR/]
    end
    slack_notify("Unable to find #{pd_name} in #{cluster_name}!", slack_k8s_snapshotter_app_webhook.to_s) if snap_schedule[/ERROR/]
    if snap_schedule.length > 1
      puts 'Found Snapshot Schedule for: ' + pd_name
    else
      # Ok, let's assign the default snapshot schedule "dailykeep14", again, might have to try in several zones.
      assignment_results = 'ERROR'
      zones.each do |zone|
        puts "Trying to ASSIGN snap_schedule for #{pd_name} in #{zone}"
        assignment_results = `gcloud compute disks add-resource-policies #{pd_name} --resource-policies dailykeep14 #{zone} 2>&1`
        puts assignment_results
        break unless assignment_results[/ERROR/]
      end
      if assignment_results[/ERROR/]
        puts 'ASSIGNMENT ERROR: ' + assignment_results
        slack_notify("Snapshot Scheduler assignment error for #{pd_name}", slack_k8s_snapshotter_app_webhook.to_s)
      else
        puts 'ASSIGNED Snapshot Schedule for:' + pd_name
      end
    end
  else
    puts "Skipping #{pv}"
  end
  puts
end

slack_notify("Snapshot Scheduler verification complete for #{cluster_name}", slack_k8s_snapshotter_app_webhook.to_s)

# Cheers!
