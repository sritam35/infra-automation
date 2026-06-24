# Bash Automation Reference

## Strict Mode Header (all scripts)
```bash
#!/bin/bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
```

## AES-256-CBC Credential Decryption
```bash
# Decrypt password stored in variable
PASSWORD=$(echo "$ENCRYPTED_PASS" | openssl enc -aes-256-cbc -d -a -pass pass:"$KEY")

# Decrypt from file
PASSWORD=$(cat /path/to/encrypted.txt | openssl enc -aes-256-cbc -d -a -pass pass:"$KEY")
```

## NetApp Cluster Iteration Pattern
```bash
CLUSTERS=("sydnasclu002" "marbkpclu003" "marnasclu003" "eu2nasclu001" "eu2nasclu003" "ashnasclu001")
OUTPUT_DIR="/mnt/global/nfs/storageautomation/outputs"
DATE=$(date +%Y%m%d)

for CLUSTER in "${CLUSTERS[@]}"; do
    log "Processing cluster: $CLUSTER"
    ssh -o StrictHostKeyChecking=no admin@${CLUSTER} \
        "volume show -vserver * -fields vserver,volume,size,used" \
        >> "${OUTPUT_DIR}/vol_report_${DATE}.csv" 2>/dev/null || \
        log "WARNING: Failed to connect to $CLUSTER"
done
```

## NetApp SSH with Filtered Output
```bash
# Fetch vserver info — csv-formatted
ssh admin@$CLUSTER "vserver show -fields vserver,type,state" | \
    awk 'NR>2 && NF>0 { printf "%s,%s,%s\n", $1,$2,$3 }' | \
    column -t -s ','
```

## HTML Email Report Generation
```bash
generate_html_report() {
    local title="$1"
    local data_file="$2"

    cat <<EOF
<html>
<head><style>
table { border-collapse: collapse; font-family: Arial; }
th { background-color: #336699; color: white; padding: 5px; }
td { border: 1px solid #ddd; padding: 4px; }
tr:nth-child(even) { background-color: #f2f2f2; }
</style></head>
<body>
<h2>$title - $(date '+%Y-%m-%d')</h2>
<table>
<tr><th>Cluster</th><th>Volume</th><th>Status</th></tr>
EOF
    while IFS=',' read -r cluster volume status; do
        echo "<tr><td>$cluster</td><td>$volume</td><td>$status</td></tr>"
    done < "$data_file"
    echo "</table></body></html>"
}

# Send via sendmail
{
    echo "To: itstorageadmins@gmo.com"
    echo "From: automation@gmo.com"
    echo "Subject: NetApp Report - $(date '+%Y-%m-%d')"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html"
    echo ""
    generate_html_report "NetApp Disk Report" /tmp/data.csv
} | sendmail -t
```

## HTML Table via Perl One-liner
```bash
# Quick HTML table from pipe-delimited input
awk -F'|' '{ print "<tr>"; for(i=1;i<=NF;i++) print "<td>"$i"</td>"; print "</tr>" }' data.txt
# Or using Perl:
perl -F'\|' -lane 'print "<tr>" . join("", map {"<td>$_</td>"} @F) . "</tr>"'
```

## Snapshot Age Check Pattern (old_snapshot.sh)
```bash
CUTOFF=$(date -d '10 days ago' '+%Y-%m-%d')
for CLUSTER in "${CLUSTERS[@]}"; do
    ssh admin@$CLUSTER "storage snapshot show -fields create-time,snapshot,volume" | \
    awk -v cutoff="$CUTOFF" 'NR>2 {
        snap_date=substr($1, 1, 10)
        if (snap_date < cutoff) print $0
    }' | while IFS= read -r snap; do
        # Extract volume and snapshot name, delete
        vol=$(echo "$snap" | awk '{print $2}')
        name=$(echo "$snap" | awk '{print $3}')
        ssh admin@$CLUSTER "storage snapshot delete -volume $vol -snapshot $name -vserver * -force"
    done
done
```

## SnapMirror Status (snapmirror.sh)
```bash
for CLUSTER in "${CLUSTERS[@]}"; do
    ssh admin@$CLUSTER "snapmirror show -fields \
        source-vserver,source-volume,destination-vserver,destination-volume,\
        status,health,lag-time,schedule" | \
    # Normalize frequency/name
    sed 's/repl_//g; s/_app//g; s/_esx//g' | \
    awk 'NR>2' >> /tmp/snapmirror_report.csv
done
```

## FPolicy Status (fpolicy.sh)
```bash
for CLUSTER in "${CLUSTERS[@]}"; do
    ssh admin@$CLUSTER "fpolicy show -vserver * -fields vserver,policy-name,status" | \
    awk 'NR>2 {
        if ($3 == "on") remark="PROTECTED"
        else remark="check-volume-state"
        print $1","$2","$3","remark
    }' >> /tmp/fpolicy_report.csv
done
# Email to security team + storage admins
```

## CSV Manipulation (AWK Join)
```bash
# Join two CSV files on first field (snapshot aggregation)
awk -F',' 'FNR==NR { data[$1]=$0; next } $1 in data { print data[$1]","$2 }' \
    file1.csv file2.csv > merged.csv

# Replace null values
sed 's/,,/,-,/g' merged.csv > cleaned.csv
```

## NFS Mount Validation (linux_mountpoint_script)
```bash
# Chef knife SSH to search fstab for volume/share patterns
knife ssh "role:app-prd" "grep -h '$VOLUME_NAME' /etc/fstab /etc/auto.*.nfs /etc/auto.home 2>/dev/null"

# Multiple environments
for ROLE in "role:app-dev" "role:app-uat" "role:app-prd"; do
    knife ssh "$ROLE" "grep -l '$SHARE_NAME' /etc/fstab" 2>/dev/null
done
```

## Vserver Inventory (cluster_vserver.sh)
```bash
OUTPUT="${OUTPUT_DIR}/vserver_$(date +%Y%m%d).csv"
echo "Cluster,Vserver,Type,State" > "$OUTPUT"

for CLUSTER in "${CLUSTERS[@]}"; do
    ssh admin@$CLUSTER "vserver show -fields vserver,type,state" | \
    awk 'NR>2 && NF>0 { printf "%s,%s,%s,%s\n", "'"$CLUSTER"'",$1,$2,$3 }' >> "$OUTPUT"
done
column -t -s',' "$OUTPUT"
sudo cp "$OUTPUT" "/mnt/global/nfs/storageautomation/outputs/"
```

## Pre/Post Reboot State Capture (maintenance_weekend_server_reboot/)
```bash
# pre_reboot.sh — capture system state before reboot
uptime        > /tmp/pre_reboot_state.txt
uname -a      >> /tmp/pre_reboot_state.txt
df -h         >> /tmp/pre_reboot_state.txt
cat /etc/fstab >> /tmp/pre_reboot_state.txt
netstat -rn   >> /tmp/pre_reboot_state.txt
ifconfig -a   >> /tmp/pre_reboot_state.txt

# LVM state
vgs  >> /tmp/pre_reboot_state.txt
lvs  >> /tmp/pre_reboot_state.txt
pvs  >> /tmp/pre_reboot_state.txt

# Boot config backup
if [ -f /etc/grub2.cfg ]; then
    cp /etc/grub2.cfg /tmp/grub2_backup.cfg
elif [ -f /etc/grub.conf ]; then
    cp /etc/grub.conf /tmp/grub_backup.conf
fi

# Multipath LUN status
multipath -ll >> /tmp/pre_reboot_state.txt

# Inject post_reboot.sh into rc.local for execution after restart
echo "/path/to/post_reboot.sh" >> /etc/rc.local
```

## Failed Disk Detection (netapp_failed_disk.sh)
```bash
for CLUSTER in "${CLUSTERS[@]}"; do
    FAILED=$(ssh admin@$CLUSTER "storage disk show -broken" | \
             sed 's/[[:space:]]\+/ /g' | awk 'NR>2 && NF>0')
    if [ -n "$FAILED" ]; then
        echo "$CLUSTER: $FAILED" >> /tmp/failed_disks.txt
    fi
done

# Send HTML email if any failed disks found
if [ -s /tmp/failed_disks.txt ]; then
    # Generate HTML table and send
fi
```
