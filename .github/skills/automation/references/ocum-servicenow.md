# OCUM → ServiceNow Integration Reference

## Architecture
OCUM fires event → Master.ps1 (receives event ID as $args[1]) → fetch event details → suppress or map → create/close ServiceNow incident

## Key Files
| File | Role |
|------|------|
| `Master.ps1` | Main orchestrator (production clusters) |
| `Master-SDW.ps1` | SDW cluster variant |
| `OCUM-getevent.ps1` | Query OCUM API by event ID |
| `OCUM-geteventMD.ps1` | Metadata variant |
| `SNWNewIncidentModule.ps1` | Create ServiceNow incident via REST |
| `SNWCloseIncidentModule.ps1` | Close incident by correlation ID |
| `SNWNewIncident.ps1` | Legacy creation (pre-module) |
| `append-message.ps1` | Timestamped log appender |
| `getstring.ps1` | String parsing utility |
| `maintenance.txt` | Suppression list (event-source-name patterns) |
| `admin.Key` + `admin.txt` | AES encrypted OCUM credentials |

## Event Properties Extracted
```
event-id, event-name, event-severity, event-impact-level, event-category
event-condition, event-source-type, event-source-name, event-state, event-time
```

## Urgency / Impact Mapping
```powershell
# Base mapping from OCUM severity/impact
$urgency = switch ($eventSeverity) { "critical" { 1 } default { 2 } }
$impact  = switch ($eventImpactLevel) { "incident" { 1 } "risk" { 2 } "event" { 3 } default { 2 } }

# Overrides (event-name based):
"Space Full"             → urgency=1, impact=1
"Some Failed Disks"      → urgency=2, impact=3
"LIF Status Down"        → urgency=1, impact=1
"Cluster Not Reachable"  → urgency=1, impact=1
"Inodes Full"            → urgency=1, impact=1
```

## Suppression Rules (exit silently, no ticket)
```powershell
# 1. Volume Offline for SDW clusters
if ($eventName -eq "Volume Offline" -and $eventSourceName -match "sdw") { exit 0 }

# 2. Space Full for cvault volumes
if ($eventName -eq "Space Full" -and $eventSourceName -match "cvault") { exit 0 }

# 3. Volume Space Nearly Full for cvault
if ($eventName -eq "Volume Space Nearly Full" -and $eventSourceName -match "cvault") { exit 0 }

# 4. Volume Growth Rate Abnormal for prdfcp (except sql012)
if ($eventName -eq "Volume Growth Rate Abnormal" -and
    $eventSourceName -match "prdfcp" -and
    $eventSourceName -notmatch "sql012") { exit 0 }

# 5. Maintenance suppression — maintenance.txt
$maintenanceHosts = Get-Content "maintenance.txt"
if ($maintenanceHosts -contains $eventSourceName) { exit 0 }
```

## Incident Creation — SNWNewIncidentModule.ps1 Parameters
```powershell
SNWNewIncidentModule.ps1 `
  -correlationid $eventId `         # OCUM event ID (deduplication key)
  -urgency $urgency `               # 1-3
  -impact $impact `                 # 1-3
  -assignmentgroup "Automation Group" `
  -category "Hardware" `
  -subcategory "NAS - Storage" `
  -worknotes "$eventProperties" `   # Concatenated event fields
  -shortdescription "${eventSeverity}: $eventName $eventSourceName - $eventId" `
  -alertsource "OCUM" `
  -affectedHCI $affectedHCI `       # Parsed from event-source-name
  -ServiceNowEnvironment "gmo"
```

## Incident Closure — Obsolete Event Flow
```powershell
# OCUM fires event with event-state = "obsolete"
if ($eventState -eq "obsolete") {
    # Close existing incident matching the correlation ID
    $exitCode = & SNWCloseIncidentModule.ps1 -CorrelationId $eventId -ServiceNowEnvironment "gmo"
    # Exit codes: 0=closed, 1=not found, 2+=error
    exit 0
}
```

## HCI Name Extraction (affectedHCI)
```powershell
# Remove hostname prefix and path separators; extract final component
# Example: "eu2nasclu001://vol_name" → "vol_name"
# Example: "cluster:vserver/volume" → "volume"
$affectedHCI = ($eventSourceName -split '[:/]')[-1]
```

## Logging Pattern
```powershell
# Per-event log: Logs\<YYYY-MM-DD>-Master-Event<eventid>.log
$logFile = "Logs\$(Get-Date -f yyyy-MM-dd)-Master-Event$eventId.log"

function Write-AppendLog {
    param([int]$logType, [string]$message)
    # logType: 0=normal, 1=warning, 2=error
    $timestamp = Get-Date -f 'yyyy-MM-dd HH:mm:ss'
    $prefix = @('INFO', 'WARN', 'ERROR')[$logType]
    Add-Content -Path $logFile -Value "[$timestamp][$prefix] $message"
}
```

## Credential Decryption (OCUM API)
```powershell
$secureKey = Get-Content "admin.Key" | ConvertTo-SecureString
$credential = New-Object System.Management.Automation.PSCredential("admin", $secureKey)
```

## OCUM REST API Pattern
```powershell
$headers = @{ Authorization = "Basic $encodedCreds"; "Content-Type" = "application/json" }
$url = "https://ocum-server/api/management-server/events/$EventId"
$response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET
$event = $response.'records'[0]
```

## Environment Credential Files
| Environment | Files |
|-------------|-------|
| Production | `admin.Key`, `admin.txt` |
| Dev | `ServiceNowDev/InboundDevUser.Key`, `InboundDevUser.txt`, `restuserdev.Key/.txt` |
| Test | `ServiceNowTest/InboundTestUser.Key/.txt` |
| Prod SNW | `ServiceNow/InboundPrdUser.Key/.txt`, `restuser.Key/.txt` |
