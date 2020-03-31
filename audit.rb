#!/usr/bin/ruby
require 'date'

# Purpose of this script is to search all PVs in the gke clusters and flag
# any that are missing the "delta" annotation.  This annotation is what tells
# the k8s-snapshots to make backups.
#
# Once annotations have been verified, a PDF report is generated showing
# the number of snapshots for each PVC, along with the creation dates of
# the oldest and newest snapshots.
#
# 2020 February 14, Michel Remillard

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
gcloud_auth_ok = `gcloud auth activate-service-account --key-file /service-account/k8s_snapshotter_audit_sa.json > /dev/null 2>&1 ; echo $?`
slack_notify('Auth to Gcloud failed.', slack_k8s_snapshotter_app_webhook.to_s) unless gcloud_auth_ok.to_i.zero?
gcloud_set_project_ok = `gcloud config set project #{gcloud_project} > /dev/null 2>&1 ; echo $?`
slack_notify('Set Gcloud project failed.', slack_k8s_snapshotter_app_webhook.to_s) unless gcloud_set_project_ok.to_i.zero?

# Select the kube context.
context_check = `#{set_context} > /dev/null 2>&1 ; echo $?`
slack_notify('Could not set kube context.', slack_k8s_snapshotter_app_webhook.to_s) unless context_check.to_i.zero?

# Get all of the physical volumes for the current context.  We only want the "Bound" volumes, not the "Available, Released, Terminating, etc." volumes.
pv_flat_list = `kubectl get pv -o=jsonpath="{.items[?(@.status.phase=='Bound')]['.metadata.name']}"`
pv_arr = pv_flat_list.split(' ')
pv_report_arr = []

# For each PV, check to see if an annotation for the snapshotter needs to be added.
pv_arr.each do |pv|
  puts "Checking #{pv} for annotation."
  pv_deleted = `kubectl describe persistentvolume #{pv} | grep backup.kubernetes.io.deltas > /dev/null 2>&1`
  if pv_deleted[/(Not Found)/]
    # As the main loop can take a while to complete, just ensure the PV has not been deleted in the mean while.
    # Example: Error from server (NotFound): persistentvolumes "pvc-dbf41f81-2e44-11ea-b136-4201ac100008" not found
    puts "This PV deleted since start of run: #{pv}."
    next
  end

  claim_line = `kubectl describe persistentvolume #{pv} | grep Claim: `
  claim_line_arr = claim_line.match(%r{^Claim:\s+(?<claim_name>[a-z0-9-]+)\/[a-z0-9-]+$})
  delta_check = `kubectl describe persistentvolume #{pv} | grep backup.kubernetes.io.deltas > /dev/null 2>&1 ; echo $?`
  if delta_check.to_i.zero?
    annotation = `kubectl describe persistentvolume #{pv} | grep backup.kubernetes.io.deltas`
    backup_schedule = annotation[/P.*$/]
    pv_report_line_arr = [claim_line_arr[:claim_name], pv, "Schedule: #{backup_schedule}"]
  else
    # The k8s-snapshots program will consider any GKE PVC which lacks "region" or "zone" within the PV Labels as an "Unsupported Volume".
    # NFS and Rook are not supported, most likely they are missing the "gcePersistentDisk" (via "get -o yaml") which points to the actual disk.
    # "Zone" and "region" appear under "labels:" as part of the "failure-domain".
    supported_volume = `kubectl describe persistentvolume #{pv} | grep failure-domain.beta.kubernetes.io > /dev/null 2>&1 ; echo $?`
    if supported_volume.to_i.zero?
      puts "Adding annotation to this PV: #{pv}."
      patch_ok = `kubectl patch persistentvolume #{pv} -p '{"metadata": {"annotations": {"backup.kubernetes.io/deltas": "P1D P14D"}}}' > /dev/null 2>&1 ; echo $?`
      slack_notify("Failed to patch #{pv}!", slack_k8s_snapshotter_app_webhook.to_s) unless patch_ok.to_i.zero?
      pv_report_line_arr = [claim_line_arr[:claim_name], pv, '{\color{blue}Added to Snapshotter Schedule}']
    else
      puts "Found unsupported volume #{pv}."
      pv_report_line_arr = [claim_line_arr[:claim_name], pv, '{\color{blue}Unsupported Volume}']
    end
  end
  pv_report_arr.push(pv_report_line_arr)
  puts "Report Line: #{pv_report_line_arr[0]} #{pv_report_line_arr[1]} #{pv_report_line_arr[2]} REPORT SIZE: #{pv_report_arr.length}"
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
puts "REPORT SIZE before sort: #{pv_report_arr.length}"
pv_report_arr.sort!

puts "Pre print array #{pv_report_arr.length}"
pv_report_arr.each do |line|
  print "PRINT REP: #{line[0]},  #{line[1]}, #{line[2]} \n"
end

pv_report_arr.each do |line|
  if line[0] != namespace
    report.push('\end{itemize}') unless namespace == ''
    namespace = line[0]
    report.push('\section{' + line[0] + '}')
    report.push('\begin{itemize}')
    puts "Preparing report for namespace: #{namespace}."
  end
  persistent_volume = line[1].match(%r{persistentvolume\/(?<persistent_volume>.+)$})
  report.push('\item PVC: ' + persistent_volume[:persistent_volume] + ' ' + line[2])
  puts 'Report line push: ' + '\item PVC: ' + persistent_volume[:persistent_volume] + ' ' + line[2] + '\n'
  # Pretty safe to assume any snapshot schedule will at least be done daily (thus "P1D"), so if we see that in the PV annotations,
  # we will check for the number of snapshots, as well as the date of the oldest and newest snapshots.
  next unless line[2].match?(/P1D/)

  # NOTE: snapshots = `gcloud compute snapshots list --filter="sourceDisk='pvc-dcfa8703-06ff-11ea-a45c-4201ac10000a' 2>&1 "`
  # The line above works fine from the command line, but gives this error when run from a script:
  # WARNING: --filter : operator evaluation is changing for consistency across Google APIs.  sourceDisk=pvc-xxx currently does not match but will match in the near future.
  snapshots = `gcloud compute snapshots list | grep #{persistent_volume[:persistent_volume]} 2>&1 `
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
    if Date.parse(timestamp_arr.max.to_s) < Date.today - 2
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

# Prepare PFD
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
