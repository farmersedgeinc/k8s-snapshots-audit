#!/usr/bin/ruby
require 'date'

# Purpose of this script is to create an audit report of all persistent volumes in the gke cluster
# which should have snapshots.  Persistent Volumes such as "local", NFS, or Rook-Ceph volumes are NOT
# backed by a "gcePersistentDisk" (as seen by the "PDName" field in a "kubectl describe persitentvolume"
# command) and thus will not have snapshots, but will still be listed in the audit report as an
# "Unsupported volume".
#
# This report checks if the persistent volume has a snapshot schedule assigned to the gce disk (as found
# by the "resourcePolicies" field), along with the number of snapshots for the persistent volume, as well
# as the dates of both the oldest and newest snapshots.  If the newest snapshot is more than a couple of
# days older then the run-date of this report, such will be highlighted in red.
#
# 2020 April 14, Michel Remillard

# Environmentals
cluster_name = ENV['CLUSTER_NAME']
gcloud_project = ENV['GCLOUD_PROJECT']
slack_channel_k8s_snapshotter_id = ENV['SLACK_CHANNEL_K8S_SNAPSHOTTER_ID']
slack_k8s_snapshotter_app_token = ENV['SLACK_K8S_SNAPSHOTTER_APP_TOKEN']
slack_k8s_snapshotter_app_webhook = ENV['SLACK_K8S_SNAPSHOTTER_APP_WEBHOOK']
set_context = ENV['SET_CONTEXT']

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
slack_notify('Set Gcloud project failed.', slack_k8s_snapshotter_app_webhook.to_s)  if gcloud_set_project_ok[/ERROR/]

# Select the kube context.
context_check = `#{set_context} 2>&1`
slack_notify('Could not set kube context.', slack_k8s_snapshotter_app_webhook.to_s) if context_check[/ERROR/]

# Get all of the physical volumes for the current context.  We only want the "Bound" volumes, not the "Available, Released, Terminating, etc." volumes.
pv_flat_list = `kubectl get pv -o=jsonpath="{.items[?(@.status.phase=='Bound')]['.metadata.name']}" 2>&1`
pv_arr = pv_flat_list.split(' ')
pv_report_arr = []

# Only the persistent volumes which are backed by a "gcePersistentDisk" (field name: "PDName") are expected to have snapshots.
pv_arr.each do |pv|
  # As the main loop can take a while to complete, just ensure the PV has not been deleted in the mean while.
  # Example: Error from server (NotFound): persistentvolumes "pvc-dbf41f81-2e44-11ea-b136-4201ac100008" not found
  pv_deleted = `kubectl describe persistentvolume #{pv} 2>&1`
  if pv_deleted[/NotFound/]
    puts "This PV deleted since start of run: #{pv}."
    next
  end

  # The claim name of the PV will be the first element of the report line.
  claim_line = `kubectl describe persistentvolume #{pv} | grep Claim: `
  claim_line_arr = claim_line.match(%r{^Claim:\s+(?<claim_name>[a-z0-9-]+)\/[a-z0-9-]+$})

  # If the PV is backed by a google disk (pdName), then we will check if the google disk has a snapshot schedule.
  pd_name = `kubectl get persistentvolume #{pv} -o=jsonpath="{['spec.gcePersistentDisk.pdName']}" 2>&1`
  if pd_name.length > 1
    puts "Supported volume #{pv}."
    # Since this is volume backed by a gce disk, let's see if there is a backup schedule assigned to it. For multi-zone disks,
    # "gcloud" will find them within a "region", but for single-zone disks, we will have to search through each zone.
    zones = ['--region us-central1', '--zone us-central1-a', '--zone us-central1-b', '--zone us-central1-c', '--zone us-central1-d', '--zone us-central1-e', '--zone us-central1-f']
    snap_schedule = 'ERROR'
    zones.each do |zone|
      puts "Trying to find snap_schedule for #{pd_name} in #{zone}"
      snap_schedule = `gcloud compute disks describe #{pd_name} #{zone} --format="value(resourcePolicies)" 2>&1`
      break unless snap_schedule[/ERROR/]
    end
    slack_notify("Unable to find #{pd_name} in #{cluster_name}!", slack_k8s_snapshotter_app_webhook.to_s) if snap_schedule[/ERROR/]
    if snap_schedule.length > 1
      snap_schedule_short_name = snap_schedule.match(%r{^.*\/([a-zA-Z0-9-]+$)})
      pv_report_line_arr = [claim_line_arr[:claim_name], pv, 'Schedule: ' + snap_schedule_short_name[1]]
    else
      pv_report_line_arr = [claim_line_arr[:claim_name], pv, 'Schedule: None']
    end
  else
    puts "Found unsupported volume #{pv}."
    pv_report_line_arr = [claim_line_arr[:claim_name], pv, '{\color{blue}Unsupported Volume}']
  end
  pv_report_arr.push(pv_report_line_arr)
  puts "Report Line: #{pv_report_line_arr[0]} #{pv_report_line_arr[1]} #{pv_report_line_arr[2]} PV COUNT: #{pv_report_arr.length}"
  puts
end

# Report Preamble
puts 'Starting report preparation.'
report = []
report.push('\documentclass[10pt]{article}')
report.push('\usepackage[margin=0.5in]{geometry}')
report.push('\usepackage{color}')
report.push('\begin{document}')
report.push('\title{GKE Snapshot Audit}')
report.push('\author{Cluster: ' + cluster_name + '}')
report.push('\date{\today}')
report.push('\maketitle')

# Report Meat and Potatoes
namespace = ''
pv_report_arr.sort!
pv_report_arr.each do |line|
  if line[0] != namespace
    report.push('\end{itemize}') unless namespace == ''
    namespace = line[0]
    report.push('\section{' + line[0] + '}')
    report.push('\begin{itemize}')
    puts "Preparing report for namespace: #{namespace}."
  end
  report.push('\item PVC: ' + line[1] + ' ' + line[2])
  # Pretty safe to assume any snapshot schedule will at least be done daily (thus "P1D"), so if we see that in the PV annotations,
  # we will check for the number of snapshots, as well as the date of the oldest and newest snapshots.
  next if line[2].match?(/Unsupported Volume/)

  # NOTE: snapshots = `gcloud compute snapshots list --filter="sourceDisk='pvc-dcfa8703-06ff-11ea-a45c-4201ac10000a' 2>&1 "`
  # The line above works fine from the command line, but gives this error when run from a script:
  # WARNING: --filter : operator evaluation is changing for consistency across Google APIs.  sourceDisk=pvc-xxx currently does not match but will match in the near future.
  snapshots = `gcloud compute snapshots list | grep #{line[1]} 2>&1 `
  if snapshots.match?(/READY/)
    timestamp_arr = []
    snapshots_arr = snapshots.split("\n") # Yeah, has to be double quotes if you don't want the literal '\n'.
    snapshots_arr.each do |single_snapshot|
      single_snapshot = single_snapshot.match(/^(?<snap_name>\S+).*$/)
      creation_timestamp = `gcloud compute snapshots describe #{single_snapshot[:snap_name]} --format="value(creationTimestamp)" 2>&1`
      # Snapshot lifecycle is "CREATING --> UPLOADING --> READY --> DELETING". Since we could hit a DELETING phase right after the snapshot
      # list was created, we would get an error trying to get the creation_timestamp, so we skip as we would not care for a deleted snapshot anyway.
      next if creation_timestamp.match?(/ERROR/)

      timestamp_arr.push(creation_timestamp)
    end
    report.push(' ')
    if Date.parse(timestamp_arr.max.to_s) < Date.today - 1
      report.push('Number of Snapshots: ' + timestamp_arr.count.to_s + ' Oldest: ' + timestamp_arr.min.to_s.chomp + ' Newest: {\color{red}' + timestamp_arr.max.to_s.chomp + '}')
    else
      report.push('Number of Snapshots: ' + timestamp_arr.count.to_s + ' Oldest: ' + timestamp_arr.min.to_s.chomp + ' Newest: {\color{blue}' + timestamp_arr.max.to_s.chomp + '}')
    end
  else
    report.push(' ')
    report.push('{\color{red}Error! Snapshots are missing!}')
  end
end

# Report Closure
report.push('\end{itemize}')
report.push('\vspace*{\fill}')
report.push('Note, PVCs which are listed as "Added to Snaphotter Schedule" have been done today and are not expected to have snapshots yet.')
report.push('Also, if snapshot dates appear in red, check it see if snapshot creation has stopped for some reason.  Check the "k8s\_snapshots" pod logs for errors and restart if need be.')
report.push('The "k8s\_snapshots" does not support ROOK, NFS, or any other volumes which do not have labels for "region" and "zone".')
report.push('\end{document}')

# Prepare PDF
`rm /tmp/#{cluster_name}.tex >/dev/null 2>&1`
`rm /tmp/#{cluster_name}.aux >/dev/null 2>&1`
`rm /tmp/#{cluster_name}.log >/dev/null 2>&1`
`rm /tmp/#{cluster_name}.pdf >/dev/null 2>&1`
tex_file = File.open("/tmp/#{cluster_name}.tex", 'w')
report.each do |report_line|
  tex_file.puts report_line
end
tex_file.close
pdf_check = `cd /tmp ; /usr/bin/pdflatex -interaction batchmode /tmp/#{cluster_name}.tex >/dev/null 2>&1 ; echo $?`
slack_notify('PDF generation failed.', slack_k8s_snapshotter_app_webhook.to_s) unless pdf_check.to_i.zero?

# Upload report file to Slack
# Seems that when this script is run locally (either from command line or inside docker) you will see a file preview on Slack.
# But when run from kubernetes, you might only see the file name (with PDF thumbnail) on Slack.
title = 'title=' + cluster_name + ' Report for ' + Date.today.to_s
upload_results = `curl -F file=@/tmp/#{cluster_name}.pdf -F "#{title}" -F channels=#{slack_channel_k8s_snapshotter_id} -H "Authorization: Bearer #{slack_k8s_snapshotter_app_token}" https://slack.com/api/files.upload`
puts 'UPLOAD RESULTS: ' + upload_results
slack_notify('Unable to upload PDF to Slack: ' + upload_results + ' ', slack_k8s_snapshotter_app_webhook.to_s) if upload_results.match?(/error/)

# Cheers!
