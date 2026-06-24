<#
.SYNOPSIS
    Quick script to retrieve and display DFS folder targets with AD site info.

.EXAMPLE
    .\Get-DFSTargets.ps1 -DFSFolderPath "\\gmo.tld\prd_eu2\Opr"

.EXAMPLE
    .\Get-DFSTargets.ps1 -DFSFolderPath "\\gmo.tld\prd_eu2\*"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$DFSFolderPath
)

function Get-TargetSite {
    param (
        [string]$DFSPath,
        [string]$TargetPath
    )
    try {
        $result = (dfsutil target $DFSPath $TargetPath 2>&1) -join ' '
        if ($result -match '\[Site:\s*(.+?)\]') {
            return $Matches[1].Trim()
        }
        return "Unknown"
    }
    catch { return "Unknown" }
}

try {
    $targets = Get-DfsnFolderTarget -Path $DFSFolderPath -ErrorAction Stop

    $output = foreach ($target in $targets) {
        $site = Get-TargetSite -DFSPath $target.Path -TargetPath $target.TargetPath

        [PSCustomObject]@{
            Path       = $target.Path
            TargetPath = $target.TargetPath
            Site       = $site
            State      = $target.State
            Priority   = $target.ReferralPriorityClass
        }
    }

    $output | Format-Table -AutoSize
}
catch {
    Write-Error "Failed to get DFS targets: $_"
}
