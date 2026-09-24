<#
.SYNOPSIS
  Inventory SQL services and databases on the local Windows host (run via Grok Bot Shell machineId).
.NOTES
  No passwords. Integrated auth. Parameterize nothing required for localhost.
#>
[CmdletBinding()]
param(
  [string]$ServerInstance = 'localhost'
)
$ErrorActionPreference = 'Continue'
Write-Output "hostname=$(hostname)"
Get-Service -Name '*SQL*' -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Output
try {
  Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop |
    Format-List | Out-String | Write-Output
} catch { Write-Output 'No SQL instance registry key' }
Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort | Format-Table -AutoSize | Out-String | Write-Output

$exe = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC' -Recurse -Filter 'SQLCMD.EXE' -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $exe) {
  Write-Output 'SQLCMD.EXE not found; trying SqlClient'
  Add-Type -AssemblyName System.Data
  $cs = "Server=$ServerInstance;Database=master;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10"
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $conn.Open()
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = @"
SELECT @@SERVERNAME AS server_name, CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version;
SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY name;
SELECT name, enabled, date_created FROM msdb.dbo.sysjobs ORDER BY name;
"@
  $r = $cmd.ExecuteReader()
  do {
    while ($r.Read()) {
      $vals = @(); for ($i=0;$i -lt $r.FieldCount;$i++) { $vals += [string]$r.GetValue($i) }
      Write-Output ($vals -join ' | ')
    }
  } while ($r.NextResult())
  $r.Close(); $conn.Close()
} else {
  & $exe -S $ServerInstance -E -W -Q "SET NOCOUNT ON; SELECT @@SERVERNAME, CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)); SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY name; SELECT name, enabled, date_created FROM msdb.dbo.sysjobs ORDER BY name;"
}
