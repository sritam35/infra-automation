param([Parameter(Mandatory = $true)][ValidateSet('1', '2', '3')]$urgency,
    [Parameter(Mandatory = $true)][ValidateSet('1', '2', '3')]$impact,
    [Parameter(Mandatory = $true)][string]$assignmentgroup,
    [Parameter(Mandatory = $true)][ValidateSet('Information Security', 'software', 'Facilities', 'IT Facilities', 'Infrastructure Services', 'Network/Voice', 'hardware', 'Logical Access', 'Production Control')]$category,
    [Parameter(Mandatory = $true)][string]$alertsource,
    [Parameter(Mandatory = $true)][string]$affectedSCI,
    [Parameter(Mandatory = $true)][string]$affectedHCI,
    [Parameter(Mandatory = $true)][string]$subcategory,
    [Parameter(Mandatory = $true)][string]$worknotes,
    [Parameter(Mandatory = $true)][string]$shortdescription,
    [Parameter(Mandatory = $true)][ValidateSet('gmodev', 'gmotest', 'gmo')]$ServiceNowEnvironment,
    [Parameter(Mandatory = $true)][string]$correlationid
)

#'------------------------------------------------------------------------------
#'Logging Functions
#'------------------------------------------------------------------------------
function Get-IsoDateTime {
    return (Get-Date -UFormat '%Y-%m-%d %H:%M:%S')
}

function Write-LogMessage {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    try {
        $timestamp = Get-IsoDateTime
        $logEntry = "$timestamp [$Level] SNWNewIncident: $Message"

        # Create logs directory if it doesn't exist
        $scriptPath = Split-Path($MyInvocation.ScriptName)
        $logsPath = Join-Path $scriptPath 'Logs'
        if (!(Test-Path $logsPath)) {
            New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
        }

        # Log to file
        $logFile = Join-Path $logsPath "$(Get-Date -UFormat '%Y-%m-%d')-SNWNewIncident.log"
        $logEntry | Out-File -FilePath $logFile -Append -Encoding ASCII

        # Also write to console for immediate feedback
        Write-Host $logEntry -ForegroundColor $(
            switch ($Level) {
                'ERROR' { 'Red' }
                'WARN' { 'Yellow' }
                'SUCCESS' { 'Green' }
                default { 'White' }
            }
        )
    } catch {
        # Fallback if logging fails
        Write-Host "LOGGING ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-LogMessage '===== SNWNewIncidentModule.ps1 Started ====='
Write-LogMessage "CorrelationId: $correlationid | AffectedHCI: $affectedHCI | Environment: $ServiceNowEnvironment"

#'------------------------------------------------------------------------------
#'CMDB Lookup Function to retrieve sys_id for affected systems
#'------------------------------------------------------------------------------
function Get-SystemSysID {
    param(
        [string]$SystemName,
        [string]$ServiceNowEnvironment = 'gmodev'
    )

    try {
        # Import the SNOW module to access CMDB functions
        Import-Module '\\gmo\dsl\SysConfig\ServiceNow\SNOW.psm1' -Force

        # Try exact match first
        try {
            $sysId = Get-SNWSysID -ci_name $SystemName -ci_type 'any' -ServiceNowEnvironment $ServiceNowEnvironment

            if (-not [string]::IsNullOrEmpty($sysId)) {
                Write-LogMessage "CMDB: Found sys_id '$sysId' for '$SystemName'" 'SUCCESS'
                return $sysId
            }
        } catch {
            Write-LogMessage "CMDB lookup error for '$SystemName': $($_.Exception.Message)" 'ERROR'
        }

        # Try fallback with short name if FQDN
        if ($SystemName -match '\.') {
            $shortName = $SystemName.Split('.')[0]
            try {
                $sysId = Get-SNWSysID -ci_name $shortName -ci_type 'any' -ServiceNowEnvironment $ServiceNowEnvironment

                if (-not [string]::IsNullOrEmpty($sysId)) {
                    Write-LogMessage "CMDB: Found sys_id '$sysId' for short name '$shortName'" 'SUCCESS'
                    return $sysId
                }
            } catch {
                Write-LogMessage "CMDB fallback lookup error for '$shortName': $($_.Exception.Message)" 'ERROR'
            }
        }

        # No sys_id found
        Write-LogMessage "CMDB: No sys_id found for '$SystemName', using hostname" 'WARN'
        return $null

    } catch {
        Write-LogMessage "CMDB: Critical error for '$SystemName': $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# Perform CMDB lookup to get sys_id for the affected system
$systemSysId = Get-SystemSysID -SystemName $affectedHCI -ServiceNowEnvironment $ServiceNowEnvironment

# Use sys_id if found, otherwise fall back to hostname
$finalAffectedHCI = if (-not [string]::IsNullOrEmpty($systemSysId)) {
    $systemSysId
} else {
    $affectedHCI
}

# set user and path to password files
$user = switch ($ServiceNowEnvironment) {
    'gmodev' { 'InboundDevUser' }
    'gmotest' { 'InboundTestUser' }
    'gmo' { 'InboundPrdUser' }
}
$fileloc = switch ($ServiceNowEnvironment) {
    'gmodev' { 'ServiceNowdev\InbounddevUser' }
    'gmotest' { 'ServiceNowtest\InboundtestUser' }
    'gmo' { 'ServiceNow\InboundPrdUser' }
}

try {
    $key = Get-Content -Path "D:\Program Files\NetApp\ocum\scriptPlugin\$fileloc.Key"
    $PasswordFile = "D:\Program Files\NetApp\ocum\scriptPlugin\$fileloc.txt"
    $MyCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user, (Get-Content $PasswordFile | ConvertTo-SecureString -Key $key)
    $pass = $MyCredential.GetNetworkCredential().Password
} catch {
    Write-LogMessage "ERROR loading ServiceNow credentials: $($_.Exception.Message)" 'ERROR'
    throw $_
}

# Build auth header
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $user, $pass)))
# Set proper headers
$headers = New-Object 'System.Collections.Generic.Dictionary[[String],[String]]'
$headers.Add('Authorization', ('Basic {0}' -f $base64AuthInfo))
$headers.Add('Accept', 'application/json')
$headers.Add('Content-Type', 'application/json')
# Specify endpoint uri
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$uri = "https://$ServiceNowEnvironment.service-now.com/api/now/table/u_inbound_staging"

# Specify HTTP method
$method = 'post'
# Specify request body
$body = "{
""u_action"":""Create Incident"",
""u_alert_source"":""$alertsource"",
""u_affected_hardware_ci"":""$finalAffectedHCI"",
""u_affected_software_ci"":""$affectedSCI"",
""u_assignment_group"":""$assignmentgroup"",
""u_category"":""$category"",
""u_correlation_id"":""$correlationid"",
""u_impact"":""$impact"",
""u_inbound_type"":""REST"",
""u_message"":""$worknotes"",
""u_subcategory"":""$subcategory"",
""u_subject"":""$shortdescription"",
""u_urgency"":""$urgency""
}"

# Send HTTP request
try {
    $response = Invoke-WebRequest -Headers $headers -Method $method -Uri $uri -Body $body -UseBasicParsing
    $getresponse = ConvertFrom-Json -InputObject $response
    $incidentId = $getresponse.result.u_result_incident_id

    if (-not [string]::IsNullOrEmpty($incidentId)) {
        Write-LogMessage "SUCCESS: Incident $incidentId created with affected_ci: $finalAffectedHCI" 'SUCCESS'
    } else {
        Write-LogMessage 'WARNING: No incident ID returned' 'WARN'
    }

    Write-LogMessage '===== SNWNewIncidentModule.ps1 Completed ====='
    return $incidentId
} catch {
    Write-LogMessage "ERROR during incident creation: $($_.Exception.Message)" 'ERROR'
    throw $_
}
