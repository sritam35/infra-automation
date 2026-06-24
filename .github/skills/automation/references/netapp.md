# NetApp ONTAP Automation Reference

## SSH Connection Pattern (Paramiko)
```python
import paramiko

def connect_ssh(host, port=22, username='admin', key_filepath=None, password=None, timeout=30):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    if key_filepath:
        client.connect(host, port=port, username=username,
                       key_filename=key_filepath, timeout=timeout)
    else:
        client.connect(host, port=port, username=username,
                       password=password, timeout=timeout)
    return client

def execute_command(ssh_client, command, timeout=60):
    stdin, stdout, stderr = ssh_client.exec_command(command, timeout=timeout)
    exit_status = stdout.channel.recv_exit_status()
    output = stdout.read().decode('utf-8')
    error = stderr.read().decode('utf-8')
    return output, error, exit_status
```

## Key SSH Credential Location
```
Private Key:  Monitoring/Private Key_svc_netapp.txt  (RSA key for svc_netapp user)
Clusters:     Monitoring/netapp_clusters.conf         (one hostname per line; # = comment)
```

## Cluster Hostname List
```python
CLUSTERS = [
    'sydnasclu002',   # Sydney
    'marbkpclu003',   # Melbourne Backup
    'marnasclu003',   # Melbourne NAS
    'eu2nasclu001',   # East US 2
    'eu2nasclu003',   # East US 2
    'ashnasclu001',   # Ashburn
]
```

## Size Parsing (ONTAP → Python)
```python
import re

def parse_size_to_bytes(size_str: str) -> int:
    """Convert ONTAP size string (100TB, 102400GB, 6.50TB) to bytes."""
    UNITS = {'b': 1, 'kb': 1024, 'mb': 1024**2, 'gb': 1024**3,
             'tb': 1024**4, 'pb': 1024**5}
    m = re.match(r'^\s*([0-9]*\.?[0-9]+)\s*([a-z]+)\s*$', size_str, re.IGNORECASE)
    if not m:
        raise ValueError(f"Cannot parse size: {size_str}")
    value, unit = float(m.group(1)), m.group(2).lower()
    return int(value * UNITS[unit])

def to_ontap_size(size_str: str) -> str:
    """Convert human-readable (6.50TB) to ONTAP CLI format (6.5t)."""
    ABBREV = {'b': 'b', 'kb': 'k', 'mb': 'm', 'gb': 'g', 'tb': 't', 'pb': 'p'}
    m = re.match(r'^\s*([0-9]*\.?[0-9]+)\s*([a-z]+)\s*$', size_str, re.IGNORECASE)
    value, unit = float(m.group(1)), m.group(2).lower()
    return f"{value:g}{ABBREV[unit]}"
```

## Common ONTAP CLI Commands (via SSH)
```bash
# Volume operations
volume show -vserver * -fields vserver,volume,size,used,available,percent-used,type
volume autosize on -vserver <svm> -volume <vol>
volume autosize modify -vserver <svm> -volume <vol> -mode grow_shrink -maximum <size>

# Snapshot operations
snap list <vol>        # Legacy 7-mode
storage snapshot show -volume <vol> -fields create-time,name  # ONTAP 9.x

# SnapMirror
snapmirror show -fields source-vserver,source-volume,destination-vserver,destination-volume,status,health,lag-time,schedule

# FPolicy
fpolicy show -vserver * -fields vserver,policy-name,status

# Disk health
storage disk show -broken

# Cluster/node health
system health subsystem show
network interface show -fields vserver,lif,operational-status,admin-status,is-home
system service-processor show

# Vserver inventory
vserver show -fields vserver,type,state,root-volume

# Aggregate capacity
aggr show -fields aggregate,node,size,used,available,percent-used,state,raid-status

# DFS vserver/volume correlation
volume show -vserver * -fields vserver,volume,junction-path,size
```

## Health Check Parsing Pattern
```python
def parse_system_health(output: str) -> list:
    """Parse 'system health subsystem show' — all subsystems must be 'ok'."""
    issues = []
    for line in output.splitlines()[2:]:  # skip header rows
        parts = re.split(r'\s{2,}', line.strip())
        if len(parts) >= 2 and parts[1].lower() != 'ok':
            issues.append({'subsystem': parts[0], 'status': parts[1]})
    return issues

def parse_network_interfaces(output: str) -> list:
    """Parse 'network interface show' — must be up/up and home=true."""
    issues = []
    for line in output.splitlines()[2:]:
        parts = re.split(r'\s{2,}', line.strip())
        if len(parts) >= 4:
            oper_status = parts[2]   # e.g., "up/up"
            is_home = parts[3]        # e.g., "true"/"false"
            if oper_status != 'up/up' or is_home != 'true':
                issues.append({'lif': parts[0], 'status': oper_status, 'home': is_home})
    return issues
```

## Autogrow Settings (netapp_set_autosize.py)
```python
# Safe system volume exclusions
SKIP_VOLUMES = ['vol0', 'node_root', 'aggr0']

# Dry-run by default; --execute flag to apply
if args.execute:
    cmd = f"volume autosize modify -vserver {svm} -volume {vol} -mode grow_shrink -maximum {ontap_size}"
    execute_command(ssh_client, cmd)
else:
    print(f"[DRY-RUN] Would run: {cmd}")
```

## Snapshot Management (Bash — old_snapshot.sh)
```bash
# AES-256-CBC password decryption pattern
PASSWORD=$(echo "$ENCRYPTED_PASS" | openssl enc -aes-256-cbc -d -a -pass pass:"$KEY")

# Delete snapshots older than 10 days
for cluster in "${CLUSTERS[@]}"; do
    ssh admin@$cluster "snap list $VOLUME" | awk -v cutoff="$CUTOFF_DATE" '{
        # parse snapshot date, delete if older
    }'
done

# HTML email report
echo "<html><table>" > /tmp/report.html
while IFS= read -r line; do
    echo "<tr><td>$line</td></tr>" >> /tmp/report.html
done
echo "</table></html>" >> /tmp/report.html
sendmail -t < /tmp/email.txt
```

## SnapMirror Report (snapmirror.sh)
```bash
# Normalize frequency field
ssh admin@$CLUSTER "snapmirror show -fields source-vserver,..." | \
    sed 's/repl_//g; s/_app//g; s/_esx//g'
```

## FPolicy Monitoring (fpolicy.sh)
```bash
# Check Varonis FPolicy protection per vserver/volume
ssh admin@$CLUSTER "fpolicy show -vserver * -fields vserver,policy-name,status" | \
    awk '{
        if ($3 == "on") print $0, "PROTECTED"
        else print $0, "check-volume-state"
    }'
```

## Aggregate/Volume Capacity Reports (Bash — Shell/)
```bash
# netapp_aggregate_capacity_report.sh
ssh admin@$CLUSTER "aggr show -fields aggregate,size,used,available,percent-used" | \
    awk 'NR>2 {print $0}' > /tmp/aggr_report.csv

# netapp_volume_capacity_report.sh
ssh admin@$CLUSTER "volume show -fields vserver,volume,size,used,available,percent-used" | \
    awk 'NR>2 {print $0}' > /tmp/vol_report.csv
```
