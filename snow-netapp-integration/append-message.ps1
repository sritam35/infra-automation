   <#
   .SYNOPSIS
   This function appends a message to log file based on the message type.
   .DESCRIPTION
   Appends a message to a log a file.
   .PARAMETER
   Accepts an integer representing the log file extension type
   .PARAMETER
   Accepts a string value containing the message to append to the log file.
   .EXAMPLE
   Append-Message -logType 0 -message "Command completed succuessfully"
   .EXAMPLE
   Append-Message -logType 2, -message "Application is not installed"
   #>
   [CmdletBinding()]
   Param(
      [Parameter(Position=0,
         Mandatory=$True,
         ValueFromPipeLine=$True,
         ValueFromPipeLineByPropertyName=$True)]
      [Int]$logType,
      [Parameter(Position=1,
         Mandatory=$True,
         ValueFromPipeLine=$True,
         ValueFromPipeLineByPropertyName=$True)]
      [String]$message
   )

   # Simple timestamp function
   $prefix = Get-Date -UFormat '%Y-%m-%d %H:%M:%S'

   # Use global scriptLogPath (set by calling script)
   $localScriptLogPath = $global:scriptLogPath

   Switch($logType){
      0 {$extension = "log"; break}
      1 {$extension = "err"; break}
      2 {$extension = "err"; break}
      3 {$extension = "csv"; break}
      default {$extension = "log"}
   }
   If($logType -eq 1){
      #$message = ("Error " + $error[0] + " " + $message)
      $message = ("Error " + $error[0].Exception.Message + " " + $message)
   }

   $logLine = $prefix + "," + $message
   $logFile = $localScriptLogPath + "." + $extension

   $logLine | Out-File -FilePath $logFile -Encoding ASCII -Append
