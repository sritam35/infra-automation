param(
   [Parameter(Mandatory = $True, HelpMessage = 'The OCUM Event ID to enumerate')]
   [Int]$EventId
   #[Parameter(Mandatory=$False, HelpMessage="The credentials to authenticate to OCUM")]
   #[System.Management.Automation.PSCredential]$Credentials
)
function Append-Message {
   param(
      [Int]$logType,
      [String]$message
   )
   switch ($logType) {
      0 { $extension = 'log'; break }
      1 { $extension = 'err'; break }
      2 { $extension = 'err'; break }
      3 { $extension = 'csv'; break }
      default { $extension = 'log' }
   }
   if ($logType -eq 1) {
      $message = ('Error ' + $error[0].Exception.Message + ' ' + $message)
   }
   $prefix = Get-Date -UFormat '%Y-%m-%d %H:%M:%S'
   ($prefix + ',' + $message) | Out-File -FilePath `
   ($scriptLogPath + '.' + $extension) -Encoding ASCII -Append
}#End Function
function Get-IsoDateTime {
   return Get-Date -UFormat '%Y-%m-%d %H:%M:%S'
}#End Function
#'------------------------------------------------------------------------------
#'Initialization Section. Define Global Variables.
#'------------------------------------------------------------------------------
[String]$scriptPath = Split-Path($MyInvocation.MyCommand.Path)
[String]$scriptSpec = $MyInvocation.MyCommand.Definition
[String]$scriptBaseName = (Get-Item $scriptSpec).BaseName
[String]$scriptName = (Get-Item $scriptSpec).Name
[String]$fileSpec = "$scriptPath\ManageOntap.dll"
[String]$zapiType = 'DFM'
[String]$zapiName = 'event-iter'
[String]$hostname = 'localhost'
[Int]$PortNumber = 443
[String]$scriptLogPath = $scriptPath + '\Logs\' + (Get-Date -UFormat '%Y-%m-%d') + '-' + $scriptBaseName + '-Event' + $EventId
#'------------------------------------------------------------------------------
#'Ensure the "Logs" folder exists within the scripts working directory.
#'------------------------------------------------------------------------------
if (-not(Test-Path "$scriptPath\Logs")) {
   try {
      New-Item -Type directory -Path "$scriptPath\Logs" -ErrorAction Stop | Out-Null
      Append-Message 0 "Created Folder ""$scriptPath\Logs"""
   } catch {
      Write-Warning -Message $("Failed creating folder ""$scriptPath\Logs"". Error " + $_.Exception.Message)
      exit -1
   }
}
#'------------------------------------------------------------------------------
#'Ensure the "ManageONTAP.dll" file exists in the scripts working directory.
#'------------------------------------------------------------------------------
if (-not(Test-Path -Path $fileSpec)) {
   Append-Message 2 "The file ""$fileSpec"" does not exist"
   exit -1
}
#'------------------------------------------------------------------------------
#'Load the ManageOntap.dll file.
#'------------------------------------------------------------------------------
try {
   [Reflection.Assembly]::LoadFile($fileSpec) | Out-Null
   Append-Message 0 "Loaded file ""$fileSpec"""
} catch {
   Append-Message 1 "Failed loading file ""$fileSpec"""
   exit -1
}
$ocumuser = 'admin'
$key = Get-Content -Path 'D:\Program Files\NetApp\ocum\scriptPlugin\admin.Key'
$PasswordFile = 'D:\Program Files\NetApp\ocum\scriptPlugin\admin.txt'
$MyCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ocumuser, (Get-Content $PasswordFile | ConvertTo-SecureString -Key $key)
$ocumPwd = $MyCredential.GetNetworkCredential().Password
#'------------------------------------------------------------------------------
#'Create a NaServer object to connect to OCUM.
#'------------------------------------------------------------------------------
try {
   [NetApp.Manage.NaServer]$naServer = New-Object NetApp.Manage.NaServer($HostName, '1', '0')
   $naServer.SetAdminUser($ocumuser, $ocumPwd)
   $naServer.ServerType = $ZapiType
   $naServer.TransportType = 'HTTPS'
   $naServer.port = $portNumber
} catch {
   Append-Message 'Failed creating NaServer object. Error ' + $_.Exception.Message
   break
}
#'------------------------------------------------------------------------------
#'Invoke the ZAPI to enumerate the OCUM event.
#'------------------------------------------------------------------------------
try {
   $naElement = New-Object NetApp.Manage.naElement($zapiName)
   $naElement.AddNewChild('event-id', $EventId)
   $naElement.AddNewChild('max-records', '1')
   [Xml]$output = $naServer.InvokeElem($naElement)
} catch {
   Append-Message 1 "Failed invoking ZAPI on ""$HostName"""
   exit -1
}
#'------------------------------------------------------------------------------
#'Set variables from ZAPI results.
#'------------------------------------------------------------------------------
$events = $output.results.'records'.'event-info'
foreach ($event in $events) {
   [String]$eventAbout = $event.'event-about'
   [String]$eventCategory = $event.'event-category'
   [String]$eventCondition = $event.'event-condition'
   [String]$eventImpactArea = $event.'event-impact-area'
   [String]$eventImpactLevel = $event.'event-impact-level'
   [String]$eventName = $event.'event-name'
   [String]$eventType = $event.'event-type'
   [String]$eventSeverity = $event.'event-severity'
   [String]$eventSourceType = $event.'event-source-type'
   [String]$eventSourceName = $event.'event-source-name'
   [String]$eventSourceResourceKey = $event.'event-source-resource-key'
   [String]$eventState = $event.'event-state'
   [String]$eventTime = [TimeZone]::CurrentTimeZone.ToLocalTime(([DateTime]'1/1/1970').AddSeconds($event.'event-time'))
   #'------------------------------------------------------------------------------
   #'Log the results.
   #'------------------------------------------------------------------------------
   #Append-Message 0 "Cluster name = $clusterName"
   #Append-Message 0 "Vserver name = $vserverName"
   Append-Message 0 "Event Category: $eventCategory"
   Append-Message 0 "Event Name: $eventName"
   Append-Message 0 "Event Severity: $eventSeverity"
   Append-Message 0 "Event Type: $eventSourceType"
   Append-Message 0 "Event Source Name: $eventSourceName"
   Append-Message 0 "Event State: $eventState"
   Append-Message 0 "Event Condition: $eventCondition"
   Append-Message 0 "Event Time Stamp: $eventTime"
   Append-Message 0 "EvenImpact: $eventImpactLevel"

}
return $events
#'------------------------------------------------------------------------------
