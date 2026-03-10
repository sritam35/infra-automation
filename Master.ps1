#$date = Get-Date -Format  "MMddyyyyHHmmss"
#New-Item -ItemType Directory -Force -Path "D:\ProgramFiles\NetApp\ocum\scriptPlugin\Folder\Date\$date"
#New-Item -ItemType Directory -Force -Path "D:\ProgramFiles\NetApp\ocum\scriptPlugin\Folder\$($args[1])"

# Remove unused functions - keeping only essential ones
function global:Write-AppendMessage {
    param(
        [int]$logType,
        [string]$message
    )

    .\append-message.ps1 $logType $message
}

# Validate arguments
try {
    if ($args.Count -eq 0 -or [string]::IsNullOrEmpty($args[1])) {
        exit 1
    }
} catch {
    exit 1
}
#'------------------------------------------------------------------------------
# Remove empty Get-StoredCredential stub
# function global:Get-StoredCredential {
#     #'------------------------------------------------------------------------------
#     #'------------------------------------------------------------------------------
#     # stub - no implementation
# }

#'------------------------------------------------------------------------------
#'set script run and log location
#'------------------------------------------------------------------------------
[String]$scriptPath = Split-Path($MyInvocation.MyCommand.Path)
[String]$scriptSpec = $MyInvocation.MyCommand.Definition
[String]$scriptBaseName = (Get-Item $scriptSpec).BaseName
[String]$scriptName = (Get-Item $scriptSpec).Name
# Use per-event log files to avoid file contention
[String]$global:scriptLogPath = $scriptPath + '\Logs\' + (Get-Date -UFormat '%Y-%m-%d') + '-' + $scriptBaseName + '-Event' + $args[1]

# Ensure Logs directory exists
try {
    if (!(Test-Path "$scriptPath\Logs")) {
        New-Item -ItemType Directory -Force -Path "$scriptPath\Logs" | Out-Null
    }
} catch {
    exit 1
}

#'------------------------------------------------------------------------------
#'start logging - 0 means normal log, 1 means error log
#'------------------------------------------------------------------------------
try {
    Write-AppendMessage -logType 0 -message "#####Start Logging for $($args[1])#####"
} catch {
    exit 1
}

try {
    Write-AppendMessage -logType 0 -message "Script executed by: $($env:USERDOMAIN)\$($env:USERNAME)"
} catch {
    # Continue execution if logging fails
}
#'------------------------------------------------------------------------------
#'Get Event information from OCUM
#'------------------------------------------------------------------------------
try {
    $event = .\OCUM-getevent.ps1 -EventId $args[1]

    # Check if event object is null before accessing properties
    if ($event -eq $null) {
        try { Write-AppendMessage -logType 2 -message "OCUM Event $($args[1]) returned null object" } catch {}
        try { Write-AppendMessage -logType 0 -message "#####End Logging for $($args[1]) #####" } catch {}
        exit 1
    }

    try { Write-AppendMessage -logType 0 -message "OCUM Event $($args[1])" } catch {}
    try { Write-AppendMessage -logType 0 -message "Step 1: Event data extracted successfully for $($args[1])" } catch {}
} catch {
    $errorMsg = "ERROR getting OCUM event: $($_.Exception.Message)"
    try {
        Write-AppendMessage -logType 2 -message $errorMsg
    } catch {
        # Continue execution
    }
    exit 1
}
#'------------------------------------------------------------------------------
#'get all event properties from $event variable.
#'------------------------------------------------------------------------------
[String]$eventAbout = $event.'event-about'
[String]$eventCategory = $event.'event-category'
[String]$eventCondition = $event.'event-condition'
[String]$eventImpactArea = $event.'event-impact-area'
[String]$eventImpact = $event.'event-impact-level'
[String]$eventName = $event.'event-name'
[String]$eventType = $event.'event-type'
[String]$eventSeverity = $event.'event-severity'
[String]$eventSourceType = $event.'event-source-type'
[String]$eventSourceName = $event.'event-source-name'
[String]$eventSourceResourceKey = $event.'event-source-resource-key'
[String]$eventState = $event.'event-state'
[String]$eventid = $event.'event-id'
[String]$eventTime = [TimeZone]::CurrentTimeZone.ToLocalTime(([DateTime]'1/1/1970').AddSeconds($event.'event-time'))

# Additional validation for critical event properties
if ([string]::IsNullOrEmpty($eventid)) {
    try { Write-AppendMessage -logType 2 -message "OCUM Event $($args[1]) has no valid event ID" } catch {}
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $($args[1]) #####" } catch {}
    exit 1
}

try { Write-AppendMessage -logType 0 -message "Step 2: Event ID validation passed for $($args[1]) - EventID: $eventid" } catch {}
#'------------------------------------------------------------------------------
#'check to make sure this is a new event, if not exit
#'------------------------------------------------------------------------------
Write-Host $eventState
try { Write-AppendMessage -logType 0 -message "Step 3: Event state check for $($args[1]) - State: $eventState" } catch {}

# Check for obsolete event and close incident if needed
if ($eventState -eq 'obsolete') {
    try { Write-AppendMessage -logType 0 -message "Step 4: Processing OBSOLETE event $($args[1])" } catch {}
    if (![string]::IsNullOrEmpty($eventid)) {
        try {
            try { Write-AppendMessage -logType 0 -message "Attempting to close incident for obsolete event $eventid" } catch {}

            # Use the updated SNWCloseIncidentModule.ps1 for incident closure - capture both output and exit code
            $closeOutput = & powershell.exe -ExecutionPolicy Bypass -File '.\SNWCloseIncidentModule.ps1' -CorrelationId $eventid -ServiceNowEnvironment 'gmo' 2>&1
            $exitCode = $LASTEXITCODE

            # Extract incident number from the output if available
            $incidentNumber = $null
            if ($closeOutput) {
                $successMatch = $closeOutput | Where-Object { $_ -match 'SUCCESS: Closed incident (SD\d+)' }
                if ($successMatch) {
                    $incidentNumber = $Matches[1]
                }
            }

            if ($exitCode -eq 0) {
                if ($incidentNumber) {
                    try { Write-AppendMessage -logType 0 -message "SNWCloseIncidentModule.ps1 completed successfully - incident $incidentNumber found and closed for event $eventid" } catch {}
                    try { Write-AppendMessage -logType 0 -message "$($args[1]) incident $incidentNumber Resolved in ServiceNow successfully" } catch {}
                } else {
                    try { Write-AppendMessage -logType 0 -message "SNWCloseIncidentModule.ps1 completed successfully - incident found and closed for event $eventid" } catch {}
                    try { Write-AppendMessage -logType 0 -message "$($args[1]) incident Resolved in ServiceNow successfully" } catch {}
                }
            } elseif ($exitCode -eq 1) {
                try { Write-AppendMessage -logType 1 -message "SNWCloseIncidentModule.ps1 completed - no incident found for event $eventid (may have been already closed or never created)" } catch {}
                try { Write-AppendMessage -logType 0 -message "$($args[1]) - no active incident found to close" } catch {}
            } else {
                try { Write-AppendMessage -logType 2 -message "SNWCloseIncidentModule.ps1 failed with exit code: $exitCode" } catch {}
                try { Write-AppendMessage -logType 2 -message "$($args[1]) incident closure failed" } catch {}
            }
        } catch {
            try { Write-AppendMessage -logType 2 -message "Error closing incident for $eventid : $($_.Exception.Message)" } catch {}
        }
    } else {
        try { Write-AppendMessage -logType 2 -message "Cannot close incident for $($args[1]) - no valid event ID available" } catch {}
    }
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $($args[1]) #####" } catch {}
    exit
}

try { Write-AppendMessage -logType 0 -message "Step 5: Event is NEW, proceeding with processing for $($args[1])" } catch {}

#'------------------------------------------------------------------------------
#'Log the results.
#'------------------------------------------------------------------------------
#Write-AppendMessage -logType 0 -message "Event ID: $eventid"
try { Write-AppendMessage -logType 0 -message "Step 6: Logging event details for $($args[1])" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Category: $eventCategory" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Name: $eventName" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Severity: $eventSeverity" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Type: $eventSourceType" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Source Name: $eventSourceName" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event State: $eventState" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Condition: $eventCondition" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) Event Time Stamp: $eventTime" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) EvenImpact: $eventImpact" } catch {}
#'------------------------------------------------------------------------------
#'Set Impact and Urgency.
#'------------------------------------------------------------------------------
try { Write-AppendMessage -logType 0 -message "Step 7: Calculating impact and urgency for $($args[1])" } catch {}

$impact = switch ($eventImpact) {
    'incident' { '1' }
    'risk' { '2' }
    'event' { '3' }
    default { 2 }
}
$urgency = switch ($eventSeverity) {
    'critical' { '1' }
    'error' { '2' }
    'warning' { '2' }
    default { 2 }
}
#'------------------------------------------------------------------------------
#'Here is where we change Urgency and Impact of an alert
#'------------------------------------------------------------------------------
if ($event.'event-name' -match 'Space Full') {
    $urgency = '1'
    $impact = '1'
}
if ($event.'event-name' -match 'Some Failed Disks') {
    $urgency = '2'
    $impact = '3'
}
if ($event.'event-name' -match 'Cluster Lacks Spare Disks') {
    $urgency = '2'
    $impact = '1'
}
if ($event.'event-name' -match 'LIF Status Down') {
    $urgency = '1'
    $impact = '1'
}
if ($event.'event-name' -match 'Cluster Not Reachable') {
    $urgency = '1'
    $impact = '1'
}
if ($event.'event-name' -match 'Storage Failover Disabled') {
    $urgency = '2'
    $impact = '1'
}
if ($event.'event-name' -match 'Storage Failover Node Status Down') {
    $urgency = '1'
    $impact = '1'
}
if ($event.'event-name' -match 'Volume Space Nearly Full') {
    $urgency = '2'
    $impact = '1'
}
if ($event.'event-name' -match 'Inodes Full') {
    $urgency = '1'
    $impact = '1'
}

#'------------------------------------------------------------------------------
#'Here is where we suppress Non-actionable alert patterns
#'------------------------------------------------------------------------------
try { Write-AppendMessage -logType 0 -message "Step 8: Checking suppression rules for $($args[1])" } catch {}

if (($event.'event-name' -match 'Volume Offline') -and ($event.'event-source-name' -match 'sdw_cl_')) {
    Write-Host "$($args[1]) is non actionable event, exiting...."
    try { Write-AppendMessage -logType 0 -message "$($args[1]) is non actionable event, exiting...." } catch {}
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
    exit
}
if (($event.'event-name' -match 'Volume Space Nearly Full') -and ($event.'event-source-name' -match 'cvault')) {
    Write-Host "$($args[1]) is non actionable event, exiting...."
    try { Write-AppendMessage -logType 0 -message "$($args[1]) is non actionable event, exiting...." } catch {}
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
    exit
}
if (($event.'event-name' -match 'Space Full') -and ($event.'event-source-name' -match 'cvault')) {
    Write-Host "$($args[1]) is non actionable event, exiting...."
    try { Write-AppendMessage -logType 0 -message "$($args[1]) is non actionable event, exiting...." } catch {}
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
    exit
}
if (($event.'event-name' -match 'Volume Days Until Full') -and ($event.'event-source-name' -match 'cvault')) {
    Write-Host "$($args[1]) is non actionable event, exiting...."
    try { Write-AppendMessage -logType 0 -message "$($args[1]) is non actionable event, exiting...." } catch {}
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
    exit
}
if (($event.'event-name' -match 'Volume Growth Rate Abnormal') -and ($event.'event-source-name' -match 'prdfcp') -and ($event.'event-source-name' -notmatch 'sql012')) {
    Write-Host "$($args[1]) is non actionable event, exiting...."
    try { Write-AppendMessage -logType 0 -message "$($args[1]) is non actionable event, exiting...." } catch {}
    try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
    exit
}
#'-------------------------------------------------------------------------------------------------------------
#'Supress tickets for storage maintenance activity based on event source info given in maintenance.txt file
#'-------------------------------------------------------------------------------------------------------------
try { Write-AppendMessage -logType 0 -message "Step 9: Checking maintenance suppression for $($args[1])" } catch {}

foreach ($maint in (Get-Content 'D:\Program Files\NetApp\ocum\scriptPlugin\maintenance.txt')) {
    if ($event.'event-source-name' -match $maint) {
        Write-Host "$($args[1]) is triggered due to maintenance activity, exiting...."
        try { Write-AppendMessage -logType 0 -message "$($args[1]) is non actionable event, exiting...." } catch {}
        try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
        exit
    }
}
#'------------------------------------------------------------------------------
#'create the incident in ServiceNOW
#'------------------------------------------------------------------------------
Write-Host 'urgency'$urgency
Write-Host 'impact'$impact
try { Write-AppendMessage -logType 0 -message "Step 10: Preparing for ServiceNow ticket creation for $($args[1])" } catch {}
try { Write-AppendMessage -logType 0 -message "$($args[1]) new Incident for $eventid" } catch {}

# Extract the affected HCI (hostname/system) from event source name
# Remove everything before "/" and ":" to get the actual system name
$affectedHCI = $eventSourceName
if ($eventSourceName -match '[:/]') {
    # Split by both : and / and take the last part (after any hostname/path info)
    $parts = $eventSourceName -split '[:/]'
    $affectedHCI = $parts[-1]  # Get the last part after splitting
}

# Log the extraction for debugging
try { Write-AppendMessage -logType 0 -message "Original event source name: $eventSourceName" } catch {}
try { Write-AppendMessage -logType 0 -message "Extracted affected HCI: $affectedHCI" } catch {}

# ServiceNow ticket creation
$shortdesc = "${eventSeverity}: $eventName $eventSourceName - $eventid"
$worknotes = "Event Category: $eventCategory<br/>Event Name: $eventName<br/>Event Type: $eventSourceType<br/>Event Source Name: $eventSourceName<br/>Event Condition: $eventCondition<br/>Event Time Stamp: $eventTime"

try {
    try { Write-AppendMessage -logType 0 -message "Step 11: Creating ServiceNow ticket for $($args[1])" } catch {}
    $newincident = & powershell.exe -ExecutionPolicy Bypass -File '.\SNWNewIncidentModule.ps1' -correlationid $eventid -urgency $urgency -impact $impact -assignmentgroup 'Automation Group' -category 'Hardware' -affectedSCI 'NetApp OnCommand' -subcategory 'NAS - Storage' -worknotes $worknotes -shortdescription $shortdesc -alertsource 'OCUM' -affectedHCI $affectedHCI -ServiceNowEnvironment gmo

    try { Write-AppendMessage -logType 0 -message "$($args[1]) new incident created $newincident" } catch {}
    try { Write-AppendMessage -logType 0 -message "Step 12: ServiceNow ticket creation completed for $($args[1])" } catch {}
} catch {
    $errorMsg = $_.Exception.Message
    try { Write-AppendMessage -logType 2 -message $errorMsg } catch {}
}
#'------------------------------------------------------------------------------
#'End Logging
#'------------------------------------------------------------------------------
try { Write-AppendMessage -logType 0 -message "#####End Logging for $eventid #####" } catch {}
