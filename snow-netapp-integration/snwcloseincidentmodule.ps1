<#
.SYNOPSIS
    Close a ServiceNow incident using correlation ID with enhanced search patterns and proper SNOW module integration.
.DESCRIPTION
    Closes a ServiceNow incident by correlation ID using the production SNOW module with multiple search patterns for reliable incident matching.
.PARAMETER CorrelationId
    The correlation ID (Event ID) to find and close the associated ServiceNow incident.
.PARAMETER ServiceNowEnvironment
    The ServiceNow environment (gmo, gmodev, gmotest).
.PARAMETER CloseNotes
    Notes to add to the closed incident.
.EXAMPLE
    .\SNWCloseIncidentModule.ps1 -CorrelationId "30097" -ServiceNowEnvironment gmodev
#>

param(
    [Parameter(Mandatory = $true)][string]$CorrelationId,
    [Parameter(Mandatory = $true)][ValidateSet('gmodev', 'gmotest', 'gmo')][string]$ServiceNowEnvironment,
    [string]$CloseNotes = 'Closed by automation as event is obsolete.'
)

# Simple logging function
function Write-CloseLog {
    param(
        [int]$logType,
        [string]$message
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "$timestamp,$message"

    # Create separate log files for each event
    $logDate = Get-Date -Format 'yyyy-MM-dd'
    $logFileName = "$logDate-SNWCloseIncident-Event$CorrelationId"
    $logPath = 'D:\Program Files\NetApp\ocum\scriptPlugin\Logs'

    if ($logType -eq 0) {
        # Normal log
        Add-Content -Path "$logPath\$logFileName.log" -Value $logMessage
    } elseif ($logType -eq 1) {
        # Warning log
        Add-Content -Path "$logPath\$logFileName.log" -Value $logMessage
    } else {
        # Error log
        Add-Content -Path "$logPath\$logFileName.err" -Value $logMessage
    }
}

# Log script start
Write-CloseLog -logType 0 -message "Closing incident for CorrelationId: $CorrelationId"

# Check SNOW module access before importing
$snowModulePath = '\fileserver\automation\SysConfig\ServiceNow\SNOW.psm1'

try {
    Import-Module $snowModulePath -Force -ErrorAction Stop
} catch {
    Write-CloseLog -logType 2 -message "Failed to import SNOW module: $($_.Exception.Message)"
    exit 1
}


function Close-ServiceNowIncident {
    param(
        [Parameter(Mandatory = $true)][string]$sys_id,
        [Parameter(Mandatory = $true)][string]$ServiceNowEnvironment,
        [string]$CloseNotes = 'Closed by automation as event is obsolete.'
    )

    $automationUser = 'a0b74c684fc383009a2d01b28110c750'  # Example sys_id for Automation User
    $assignmentGroup = 'e45d2fdb1b53e8d0ddd00d45624bcb92' # Example sys_id for SNWOpsEng

    $body = @{
        work_notes           = 'Resolving ticket via automation.'
        assigned_to          = $automationUser
        assignment_group     = $assignmentGroup
        resolved_by          = $automationUser
        state                = '6'  # 6 = Resolved
        incident_state       = '6'  # Explicit incident state field
        close_code           = 'Completed - Success'
        close_notes          = $CloseNotes
        u_resolution_applied = 'Automation confirmed event closure.'
        u_root_cause         = 'Automated event lifecycle closure.'
    } | ConvertTo-Json

    $closeUri = "https://$ServiceNowEnvironment.service-now.com/api/now/table/incident/$sys_id"

    try {
        $response = New-SNWRequest -Method Patch -Uri $closeUri -ServiceNowEnvironment $ServiceNowEnvironment -body $body

        # Alternative verification: Check if any active incidents still exist for this correlation ID
        Start-Sleep -Seconds 2
        try {
            $verifyQuery = "?sysparm_query=short_descriptionLIKE$CorrelationId^active=true^stateNOT IN6"
            $verifyUri = "https://$ServiceNowEnvironment.service-now.com/api/now/table/incident$verifyQuery&sysparm_fields=sys_id,number,state&sysparm_limit=1"
            $verifyResult = New-SNWRequest -Method Get -Uri $verifyUri -ServiceNowEnvironment $ServiceNowEnvironment

            if (-not $verifyResult.result -or $verifyResult.result.Count -eq 0) {
                Write-CloseLog -logType 0 -message 'Successfully closed incident - No active incidents found for correlation ID'
            } else {
                Write-CloseLog -logType 1 -message "Warning: Found $($verifyResult.result.Count) active incident(s) still exist for correlation ID"
            }
        } catch {
            Write-CloseLog -logType 1 -message 'Verification query failed, but close API call was successful'
        }

        Write-CloseLog -logType 0 -message 'Successfully closed incident - API call completed'
        return $true
    } catch {
        Write-CloseLog -logType 2 -message "Error closing incident sys_id ${sys_id}: $($_.Exception.Message)"
        return $false
    }
}

# Enhanced search query with multiple patterns - includes New (1) and Pending Automation (20) states
$queries = @(
    "?sysparm_query=short_descriptionLIKE$CorrelationId^active=true^stateIN1,20",
    "?sysparm_query=short_descriptionCONTAINS$CorrelationId^active=true^stateIN1,20",
    "?sysparm_query=short_descriptionENDSWITH$CorrelationId^active=true^stateIN1,20",
    "?sysparm_query=correlation_id=$CorrelationId^active=true^stateIN1,20"
)

$fields = '&sysparm_fields=sys_id,number,short_description,correlation_id,state&sysparm_limit=5'
$incident = $null

foreach ($query in $queries) {
    $uri = "https://$ServiceNowEnvironment.service-now.com/api/now/table/incident$query$fields"

    try {
        $request = New-SNWRequest -Method 'get' -Uri $uri -ServiceNowEnvironment $ServiceNowEnvironment
        $result = $request.result

        if ($result -and $result.Count -gt 0) {
            $incident = $result[0]
            Write-CloseLog -logType 0 -message "Found incident: $($incident.number) | State: $($incident.state)"
            break
        }
    } catch {
        Write-CloseLog -logType 2 -message "Search error for query '$query': $($_.Exception.Message)"
        continue
    }
}

if (-not $incident) {
    Write-CloseLog -logType 1 -message "No incident found for correlation_id: $CorrelationId"
    exit 1
}

$incidentSysId = $incident.sys_id
$incidentNum = $incident.number
$incidentState = $incident.state

if ($incidentState -eq '6' -or $incidentState -eq 'Closed' -or $incidentState -eq 'Resolved') {
    Write-CloseLog -logType 0 -message "Incident $incidentNum already closed"
    exit 0
}

$success = Close-ServiceNowIncident -sys_id $incidentSysId -ServiceNowEnvironment $ServiceNowEnvironment -CloseNotes $CloseNotes

if ($success) {
    Write-CloseLog -logType 0 -message "SUCCESS: Closed incident $incidentNum"
    Write-Output "SUCCESS: Closed incident $incidentNum for event $CorrelationId"
    exit 0
} else {
    Write-CloseLog -logType 2 -message "Failed to close incident $incidentNum"
    exit 1
}
