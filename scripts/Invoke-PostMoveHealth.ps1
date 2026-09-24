#Requires -Version 5.1
<#
.SYNOPSIS
  Post-move backup verification: services, Agent jobs, configured backup paths, smoke + VERIFYONLY.
  Instance topology (backup roots, job names, optional archive path) comes from instances.json via the catalog wrapper.
  Does NOT delete archived backup trees. Windows integrated security only.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SqlHost,
  [Parameter(Mandatory = $true)]
  [string]$ReportRoot,
  [Parameter(Mandatory = $true)]
  [string[]]$InstanceIds,
  [Parameter(Mandatory = $true)]
  [string]$DbaInstancesJson,
  [string]$ArchiveJson,
  [int]$SmokeWaitSeconds = 900,
  [int]$FreshMinutes = 15
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$OutJson = Join-Path $ReportRoot ("post_move_health_{0}.json" -f $stamp)
$OutTxt  = Join-Path $ReportRoot ("post_move_health_{0}.txt" -f $stamp)
$OutLog  = Join-Path $ReportRoot ("post_move_health_{0}.log" -f $stamp)

New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '{0}  [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  Write-Host $line
  Add-Content -LiteralPath $OutLog -Value $line -Encoding UTF8
}

function Add-Finding {
  param($Bag, [string]$Severity, [string]$Code, [string]$Message)
  $Bag.findings += [ordered]@{
    severity = $Severity
    code     = $Code
    message  = $Message
  }
  if ($Severity -eq 'FAIL') { $Bag.fail_count++ }
  Write-Log ("{0}: {1} - {2}" -f $Severity, $Code, $Message) $(if ($Severity -eq 'FAIL') { 'FAIL' } else { 'WARN' })
}

function Convert-DriveToUnc {
  param([string]$Path)
  if ($Path -match '^([A-Za-z]):(\\.*)$') {
    return ('\\{0}\{1}${2}' -f $SqlHost, $Matches[1], $Matches[2])
  }
  if ($Path -match '^([A-Za-z]):\\?$') {
    return ('\\{0}\{1}$' -f $SqlHost, $Matches[1])
  }
  return $Path
}

function Invoke-SqlReader {
  param(
    [string]$Instance,
    [string]$Query,
    [string]$Database = 'master',
    [int]$TimeoutSec = 180
  )
  $cs = "Server=$SqlHost\$Instance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=60;"
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $Query
  $cmd.CommandTimeout = $TimeoutSec
  $rows = New-Object System.Collections.Generic.List[object]
  try {
    $conn.Open()
    $rdr = $cmd.ExecuteReader()
    $fieldCount = $rdr.FieldCount
    $names = @()
    for ($i = 0; $i -lt $fieldCount; $i++) { $names += $rdr.GetName($i) }
    while ($rdr.Read()) {
      $o = [ordered]@{}
      for ($i = 0; $i -lt $fieldCount; $i++) {
        if ($rdr.IsDBNull($i)) { $o[$names[$i]] = $null }
        else { $o[$names[$i]] = $rdr.GetValue($i) }
      }
      [void]$rows.Add([pscustomobject]$o)
    }
    $rdr.Close()
  } finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $conn.Dispose()
  }
  return ,$rows.ToArray()
}

function Invoke-SqlNonQuery {
  param(
    [string]$Instance,
    [string]$Query,
    [string]$Database = 'master',
    [int]$TimeoutSec = 600
  )
  $cs = "Server=$SqlHost\$Instance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=60;"
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $Query
  $cmd.CommandTimeout = $TimeoutSec
  try {
    $conn.Open()
    [void]$cmd.ExecuteNonQuery()
  } finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $conn.Dispose()
  }
}

function Invoke-SqlScalar {
  param(
    [string]$Instance,
    [string]$Query,
    [string]$Database = 'master',
    [int]$TimeoutSec = 120
  )
  $cs = "Server=$SqlHost\$Instance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=60;"
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $Query
  $cmd.CommandTimeout = $TimeoutSec
  try {
    $conn.Open()
    return $cmd.ExecuteScalar()
  } finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $conn.Dispose()
  }
}

function Get-RemoteServiceState {
  param([string]$ServiceName)
  # Prefer sc.exe against remote; fall back Get-Service via CIM
  $out = @{ name = $ServiceName; status = $null; start_type = $null; ok = $false; detail = $null }
  try {
    $sc = & sc.exe "\\$SqlHost" query $ServiceName 2>&1 | Out-String
    if ($sc -match 'STATE\s+:\s+\d+\s+(\w+)') {
      $out.status = $Matches[1]
      $out.ok = ($Matches[1] -eq 'RUNNING')
    } else {
      $out.detail = $sc.Trim()
    }
    $sc2 = & sc.exe "\\$SqlHost" qc $ServiceName 2>&1 | Out-String
    if ($sc2 -match 'START_TYPE\s+:\s+\d+\s+(\w+)') { $out.start_type = $Matches[1] }
  } catch {
    $out.detail = $_.Exception.Message
  }
  if (-not $out.status) {
    try {
      $svc = Get-CimInstance -ComputerName $SqlHost -ClassName Win32_Service -Filter ("Name='{0}'" -f ($ServiceName -replace "'","''")) -ErrorAction Stop
      $out.status = $svc.State
      $out.start_type = $svc.StartMode
      $out.ok = ($svc.State -eq 'Running')
    } catch {
      $out.detail = (($out.detail + '; ' + $_.Exception.Message).Trim('; '))
    }
  }
  return [pscustomobject]$out
}

function Get-NewestFiles {
  param([string]$LocalPath, [string]$Filter, [datetime]$Since)
  $unc = Convert-DriveToUnc $LocalPath
  $result = @{
    path_local = $LocalPath
    path_unc   = $unc
    exists     = $false
    newest     = @()
    new_since_count = 0
  }
  if (-not (Test-Path -LiteralPath $unc)) { return [pscustomobject]$result }
  $result.exists = $true
  $files = @(Get-ChildItem -LiteralPath $unc -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
  $result.new_since_count = @($files | Where-Object { $_.LastWriteTime -ge $Since }).Count
  $top = @($files | Select-Object -First 5)
  foreach ($f in $top) {
    $result.newest += [ordered]@{
      name = $f.Name
      full_name = $f.FullName
      length = $f.Length
      last_write = $f.LastWriteTime.ToString('o')
      age_minutes = [math]::Round(((Get-Date) - $f.LastWriteTime).TotalMinutes, 1)
    }
  }
  return [pscustomobject]$result
}

function Wait-JobOutcome {
  param([string]$Instance, [string]$JobName, [datetime]$StartedAfter, [int]$MaxSeconds)
  $deadline = (Get-Date).AddSeconds($MaxSeconds)
  $esc = $JobName -replace "'","''"
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 8
    $q = @"
SELECT TOP 1
  CASE h.run_status
    WHEN 0 THEN 'Failed'
    WHEN 1 THEN 'Succeeded'
    WHEN 2 THEN 'Retry'
    WHEN 3 THEN 'Canceled'
    WHEN 4 THEN 'InProgress'
    ELSE CAST(h.run_status AS varchar(12))
  END AS run_status,
  h.run_date, h.run_time, h.run_duration,
  LEFT(REPLACE(REPLACE(h.message, CHAR(13), ' '), CHAR(10), ' '), 2000) AS message
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id
WHERE j.name = N'$esc' AND h.step_id = 0
ORDER BY h.instance_id DESC;
"@
    try {
      $rows = Invoke-SqlReader -Instance $Instance -Query $q
      if ($rows.Count -gt 0) {
        $r = $rows[0]
        $rd = [string]$r.run_date
        $rt = ('{0:D6}' -f [int]$r.run_time)
        if ($rd -match '^\d{8}$' -and $rt -match '^\d{6}$') {
          $runAt = [datetime]::ParseExact(($rd + $rt), 'yyyyMMddHHmmss', $null)
          if ($runAt -ge $StartedAfter.AddMinutes(-1)) {
            if ($r.run_status -ne 'InProgress' -and $r.run_status -ne 'Retry') {
              return [pscustomobject]@{
                run_status = [string]$r.run_status
                run_date = $rd
                run_time = $rt
                run_duration = $r.run_duration
                message = [string]$r.message
                run_at = $runAt.ToString('o')
              }
            }
          }
        }
      }
    } catch {
      Write-Log ("Wait-JobOutcome poll error: {0}" -f $_.Exception.Message) 'WARN'
    }
  }
  return [pscustomobject]@{
    run_status = 'Timeout'
    message = "No completed run within ${MaxSeconds}s after start"
  }
}

function ConvertTo-PostMoveInstanceConfig {
  param($Row)
  $instName = if ($Row.sqlInstanceName) { [string]$Row.sqlInstanceName } else { [string]$Row.id }
  $jobs = @()
  if ($Row.expectedJobs) { $jobs = @($Row.expectedJobs | ForEach-Object { [string]$_ }) }
  return [ordered]@{
    name              = $instName
    sql_svc           = [string]$Row.sqlService
    agent_svc         = [string]$Row.agentService
    backup_root       = [string]$Row.backupRoot
    old_f_backup      = [string]$Row.oldFBackupRoot
    archive_folder    = if ($Row.archiveFolder) { [string]$Row.archiveFolder } else { $instName }
    expected_recovery = [string]$Row.expectedRecovery
    expected_jobs     = $jobs
    smoke_job         = [string]$Row.smokeJob
    smoke_ext         = if ($Row.smokeExt) { [string]$Row.smokeExt } else { '*.bak' }
    f_folder_prefix   = [string]$Row.dataMountPrefix
    simple_temp_db    = if ($Row.simpleTempDb) { [string]$Row.simpleTempDb } else { $null }
  }
}

$parsedRows = @($DbaInstancesJson | ConvertFrom-Json)
$wanted = @($InstanceIds | ForEach-Object { [string]$_ })
$instConfig = @()
foreach ($row in $parsedRows) {
  $key = if ($row.sqlInstanceName) { [string]$row.sqlInstanceName } else { [string]$row.id }
  if ($wanted.Count -gt 0 -and $key -notin $wanted -and [string]$row.id -notin $wanted) { continue }
  $instConfig += ConvertTo-PostMoveInstanceConfig -Row $row
}
if ($instConfig.Count -eq 0) {
  Write-Error 'No dbaInstances rows match instanceIds.'
  exit 2
}

$report = [ordered]@{
  title = 'MSSQL post-move backup health'
  host = $SqlHost
  hostname_label = $SqlHost
  collector = ('{0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
  started_local = $started.ToString('o')
  finished_local = $null
  overall = 'PASS'
  fail_count = 0
  findings = @()
  disk = $null
  archive = $null
  instances = @()
  suggested_human_hours = 1.25
  notes = @(
    'Does not delete anything on I: or F:.',
    'Smoke jobs write new files to G: only.',
    'Probe files on G: backup roots are created then deleted.'
  )
}

Write-Log "=== Post-move health start on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME ==="
Write-Log "Target SQL host $SqlHost; report $OutJson"

# ---------- 12. Disk free F:/G:/I: ----------
$diskInfo = [ordered]@{ volumes = @(); method = $null; error = $null }
try {
  $vols = Get-CimInstance -ComputerName $SqlHost -ClassName Win32_Volume -ErrorAction Stop
  $diskInfo.method = 'Win32_Volume'
  foreach ($v in @($vols)) {
    $letter = $null
    if ($v.DriveLetter) { $letter = [string]$v.DriveLetter.TrimEnd(':') }
    elseif ($v.Name -match '^([A-Za-z]):') { $letter = $Matches[1] }
    if ($letter -in @('F','G','I') -or ($v.Name -match '^[FGI]:\\')) {
      $cap = if ($v.Capacity) { [math]::Round($v.Capacity/1GB, 2) } else { $null }
      $free = if ($null -ne $v.FreeSpace) { [math]::Round($v.FreeSpace/1GB, 2) } else { $null }
      $pct = if ($v.Capacity -and $null -ne $v.FreeSpace) { [math]::Round(100.0*$v.FreeSpace/$v.Capacity, 2) } else { $null }
      $diskInfo.volumes += [ordered]@{
        name = $v.Name
        label = $v.Label
        drive = $letter
        capacity_gb = $cap
        free_gb = $free
        free_pct = $pct
      }
    }
  }
} catch {
  $diskInfo.error = $_.Exception.Message
  Write-Log ("Disk WMI failed: {0}" -f $_.Exception.Message) 'WARN'
  try {
    $ld = Get-CimInstance -ComputerName $SqlHost -ClassName Win32_LogicalDisk -ErrorAction Stop |
      Where-Object { $_.DeviceID -in @('F:','G:','I:') }
    $diskInfo.method = 'Win32_LogicalDisk'
    foreach ($d in @($ld)) {
      $diskInfo.volumes += [ordered]@{
        name = $d.DeviceID
        label = $d.VolumeName
        drive = $d.DeviceID.TrimEnd(':')
        capacity_gb = if ($d.Size) { [math]::Round($d.Size/1GB, 2) } else { $null }
        free_gb = if ($null -ne $d.FreeSpace) { [math]::Round($d.FreeSpace/1GB, 2) } else { $null }
        free_pct = if ($d.Size) { [math]::Round(100.0*$d.FreeSpace/$d.Size, 2) } else { $null }
      }
    }
  } catch {
    $diskInfo.error = ($diskInfo.error + '; ' + $_.Exception.Message)
  }
}
$report.disk = $diskInfo

# ---------- Optional archive intact (only when configured) ----------
$archiveInfo = [ordered]@{ configured = $false; path = $null; unc = $null; exists = $false; folders = @() }
if ($ArchiveJson) {
  $arch = $ArchiveJson | ConvertFrom-Json
  if ($arch -and $arch.root) {
    $archiveRoot = [string]$arch.root
    $archiveUnc = Convert-DriveToUnc $archiveRoot
    $archiveInfo.configured = $true
    $archiveInfo.path = $archiveRoot
    $archiveInfo.unc = $archiveUnc
    $folderSpecs = @()
    if ($arch.folders) { $folderSpecs = @($arch.folders) }
    if (Test-Path -LiteralPath $archiveUnc) {
      $archiveInfo.exists = $true
      foreach ($spec in $folderSpecs) {
        $fold = [string]$spec.name
        $p = Join-Path $archiveUnc $fold
        $entry = [ordered]@{ name = $fold; exists = $false; file_count = 0; expected_approx = $null }
        if ($null -ne $spec.expectedCountApprox) { $entry.expected_approx = [int]$spec.expectedCountApprox }
        if (Test-Path -LiteralPath $p) {
          $entry.exists = $true
          $entry.file_count = @(Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue).Count
          if ($null -ne $entry.expected_approx) {
            $exp = [int]$entry.expected_approx
            $lo = [math]::Max(0, [int]($exp * 0.5))
            $hi = [int]($exp * 2.5) + 50
            if ($entry.file_count -lt $lo -or $entry.file_count -gt $hi) {
              Add-Finding $report 'FAIL' 'ARCHIVE_COUNT' ("Archive {0} file_count={1} outside rough band ~{2} (band {3}-{4})" -f $fold, $entry.file_count, $exp, $lo, $hi)
            } else {
              Write-Log ("Archive {0}: {1} files (expected ~{2})" -f $fold, $entry.file_count, $exp)
            }
          } else {
            Write-Log ("Archive {0}: {1} files" -f $fold, $entry.file_count)
          }
        } else {
          Add-Finding $report 'FAIL' 'ARCHIVE_MISSING' ("Archive folder missing: {0}\{1}" -f $archiveRoot, $fold)
        }
        $archiveInfo.folders += $entry
      }
    } else {
      Add-Finding $report 'FAIL' 'ARCHIVE_ROOT' ("Archive root not found: $archiveRoot ($archiveUnc)")
    }
  }
}
$report.archive = $archiveInfo

# ---------- Per instance ----------
foreach ($cfg in $instConfig) {
  $inst = [string]$cfg.name
  Write-Log "======== INSTANCE $inst ========"
  $ir = [ordered]@{
    instance = $inst
    services = $null
    connectivity = $null
    backup_directory = $null
    backup_path_writable = $null
    agent_jobs = $null
    enabled_f_path_jobs = @()
    disabled_old_f_jobs = @()
    recovery = $null
    log_reuse = $null
    smoke = $null
    verifyonly = $null
    old_f_backup = $null
    fail_findings = @()
  }

  # 1. Services
  $sqlSvc = Get-RemoteServiceState $cfg.sql_svc
  $agtSvc = Get-RemoteServiceState $cfg.agent_svc
  $ir.services = [ordered]@{ sql = $sqlSvc; agent = $agtSvc }
  if (-not $sqlSvc.ok) { Add-Finding $report 'FAIL' 'SVC_SQL' ("$inst SQL service $($cfg.sql_svc) not Running: $($sqlSvc.status)"); $ir.fail_findings += 'SVC_SQL' }
  if (-not $agtSvc.ok) { Add-Finding $report 'FAIL' 'SVC_AGENT' ("$inst Agent $($cfg.agent_svc) not Running: $($agtSvc.status)"); $ir.fail_findings += 'SVC_AGENT' }

  # 2. Connectivity
  try {
    $meta = Invoke-SqlReader -Instance $inst -Query @"
SELECT @@SERVERNAME AS server_name,
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
       LEFT(@@VERSION, 200) AS version_short,
       (SELECT COUNT(*) FROM sys.databases) AS database_count;
"@
    $dbs = Invoke-SqlReader -Instance $inst -Query @"
SELECT name, state_desc, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE database_id > 4
ORDER BY name;
"@
    $online = @($dbs | Where-Object { $_.state_desc -eq 'ONLINE' })
    $notOnline = @($dbs | Where-Object { $_.state_desc -ne 'ONLINE' })
    $ir.connectivity = [ordered]@{
      ok = $true
      server_name = if ($meta.Count -gt 0) { [string]$meta[0].server_name } else { $null }
      product_version = if ($meta.Count -gt 0) { [string]$meta[0].product_version } else { $null }
      version_short = if ($meta.Count -gt 0) { [string]$meta[0].version_short } else { $null }
      database_count = if ($meta.Count -gt 0) { [int]$meta[0].database_count } else { 0 }
      user_dbs_online = @($online | ForEach-Object { $_.name })
      user_dbs_not_online = @($notOnline | ForEach-Object { [ordered]@{ name = $_.name; state = $_.state_desc } })
    }
    if ($notOnline.Count -gt 0) {
      Add-Finding $report 'FAIL' 'DB_NOT_ONLINE' ("$inst user DBs not ONLINE: " + (($notOnline | ForEach-Object { $_.name + '=' + $_.state_desc }) -join ', '))
      $ir.fail_findings += 'DB_NOT_ONLINE'
    }
    Write-Log ("$inst connected as {0}; user DBs online={1} not_online={2}" -f $ir.connectivity.server_name, $online.Count, $notOnline.Count)
  } catch {
    $ir.connectivity = [ordered]@{ ok = $false; error = $_.Exception.Message }
    Add-Finding $report 'FAIL' 'CONNECT' ("$inst connectivity failed: $($_.Exception.Message)")
    $ir.fail_findings += 'CONNECT'
    $report.instances += $ir
    continue
  }

  # 3. BackupDirectory
  try {
    $bdRows = Invoke-SqlReader -Instance $inst -Query @"
DECLARE @v nvarchar(512) = NULL;
BEGIN TRY
  EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'BackupDirectory',
    @v OUTPUT;
END TRY BEGIN CATCH
  SET @v = NULL;
END CATCH
SELECT ISNULL(@v,'(null)') AS BackupDirectory;
"@
    $bd = if ($bdRows.Count -gt 0) { [string]$bdRows[0].BackupDirectory } else { '(null)' }
    $bdOk = ($bd -like 'G:\*') -and ($bd -like '*\Backup*') -and ($bd -notlike 'F:\*')
    $ir.backup_directory = [ordered]@{ value = $bd; ok = [bool]$bdOk; expected_under = $cfg.backup_root }
    if (-not $bdOk) {
      Add-Finding $report 'FAIL' 'BACKUPDIR' ("$inst BackupDirectory='$bd' must be under G:\...\Backup not F:")
      $ir.fail_findings += 'BACKUPDIR'
    } else {
      Write-Log ("$inst BackupDirectory OK: $bd")
    }
  } catch {
    $ir.backup_directory = [ordered]@{ value = $null; ok = $false; error = $_.Exception.Message }
    Add-Finding $report 'FAIL' 'BACKUPDIR' ("$inst BackupDirectory read failed: $($_.Exception.Message)")
    $ir.fail_findings += 'BACKUPDIR'
  }

  # 4. Default backup path writable (G: only probe)
  $bakUnc = Convert-DriveToUnc $cfg.backup_root
  $probe = [ordered]@{
    path = $cfg.backup_root
    unc = $bakUnc
    exists = $false
    writable = $false
    probe_file = $null
    error = $null
  }
  try {
    if (-not (Test-Path -LiteralPath $bakUnc)) {
      New-Item -ItemType Directory -Force -Path $bakUnc | Out-Null
    }
    $probe.exists = Test-Path -LiteralPath $bakUnc
    $probeName = Join-Path $bakUnc ("__post_move_probe_{0}.txt" -f $stamp)
    $probe.probe_file = $probeName
    Set-Content -LiteralPath $probeName -Value 'probe' -Encoding ASCII
    if (Test-Path -LiteralPath $probeName) {
      $probe.writable = $true
      Remove-Item -LiteralPath $probeName -Force -ErrorAction Stop
    }
  } catch {
    $probe.error = $_.Exception.Message
  }
  $ir.backup_path_writable = $probe
  if (-not $probe.writable) {
    Add-Finding $report 'FAIL' 'BACKUP_WRITABLE' ("$inst backup root not writable: $($cfg.backup_root) - $($probe.error)")
    $ir.fail_findings += 'BACKUP_WRITABLE'
  } else {
    Write-Log ("$inst backup root writable: $($cfg.backup_root)")
  }

  # Old F: backup folder status (expect absent/empty - do not delete)
  $fUnc = Convert-DriveToUnc $cfg.old_f_backup
  $fInfo = [ordered]@{ path = $cfg.old_f_backup; exists = $false; file_count = 0 }
  if (Test-Path -LiteralPath $fUnc) {
    $fInfo.exists = $true
    $fInfo.file_count = @(Get-ChildItem -LiteralPath $fUnc -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($fInfo.file_count -gt 0) {
      Add-Finding $report 'WARN' 'OLD_F_NONEMPTY' ("$inst old F: backup path still has {0} files (not deleted by this script): {1}" -f $fInfo.file_count, $cfg.old_f_backup)
    }
  }
  $ir.old_f_backup = $fInfo

  # 5+6. Agent jobs - expected present/enabled; F: path enabled = FAIL; old F jobs disabled
  try {
    $jobRows = Invoke-SqlReader -Instance $inst -Query @"
SELECT j.name AS job_name, j.enabled,
  CASE h.run_status
    WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 2 THEN 'Retry'
    WHEN 3 THEN 'Canceled' WHEN 4 THEN 'InProgress'
    ELSE ISNULL(CAST(h.run_status AS varchar(12)),'')
  END AS last_status,
  h.run_date, h.run_time,
  LEFT(REPLACE(REPLACE(ISNULL(h.message,''), CHAR(13),' '), CHAR(10),' '), 500) AS last_message
FROM msdb.dbo.sysjobs j
OUTER APPLY (
  SELECT TOP 1 run_status, run_date, run_time, message
  FROM msdb.dbo.sysjobhistory h
  WHERE h.job_id = j.job_id AND h.step_id = 0
  ORDER BY h.instance_id DESC
) h
ORDER BY j.name;
"@
    $stepRows = Invoke-SqlReader -Instance $inst -Query @"
SELECT j.name AS job_name, j.enabled, js.step_id, js.step_name,
  LEFT(REPLACE(REPLACE(js.command, CHAR(9),' '), CHAR(13)+CHAR(10),' '), 4000) AS command
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
ORDER BY j.name, js.step_id;
"@

    $stdJobs = @()
    foreach ($jn in @($cfg.expected_jobs)) {
      $match = @($jobRows | Where-Object { $_.job_name -eq $jn })
      $entry = [ordered]@{ name = $jn; exists = ($match.Count -gt 0); enabled = $null; last_status = $null }
      if ($match.Count -gt 0) {
        $entry.enabled = [int]$match[0].enabled
        $entry.last_status = [string]$match[0].last_status
        if ([int]$match[0].enabled -ne 1) {
          Add-Finding $report 'FAIL' 'JOB_DISABLED' ("$inst expected job '$jn' exists but Enabled=0")
          $ir.fail_findings += 'JOB_DISABLED'
        }
      } else {
        Add-Finding $report 'FAIL' 'JOB_MISSING' ("$inst expected job '$jn' missing")
        $ir.fail_findings += 'JOB_MISSING'
      }
      $stdJobs += $entry
    }
    $ir.agent_jobs = $stdJobs

    $fPrefix = [string]$cfg.f_folder_prefix
    $enabledF = @()
    $jobNamesWithF = @{}
    for ($i = 0; $i -lt $stepRows.Count; $i++) {
      $s = $stepRows[$i]
      $cmd = [string]$s.command
      $hitsF = ($fPrefix -and $cmd.Contains($fPrefix)) -or ($cmd -match 'F:\\[^\\]+\\.*\\Backup')
      if ($hitsF) {
        $jobNamesWithF[[string]$s.job_name] = $true
        if ([int]$s.enabled -eq 1) {
          $enabledF += [ordered]@{
            job_name = [string]$s.job_name
            step_id = [int]$s.step_id
            step_name = [string]$s.step_name
            command_preview = $cmd.Substring(0, [math]::Min(240, $cmd.Length))
          }
        }
      }
    }
    $ir.enabled_f_path_jobs = $enabledF
    if ($enabledF.Count -gt 0) {
      $names = ($enabledF | ForEach-Object { $_.job_name } | Select-Object -Unique) -join ', '
      Add-Finding $report 'FAIL' 'ENABLED_F_JOB' ("$inst ENABLED job(s) still target F: backup paths: $names")
      $ir.fail_findings += 'ENABLED_F_JOB'
    }

    # Old F jobs should remain disabled
    $disabledOld = @()
    foreach ($jn in @($jobNamesWithF.Keys)) {
      $j = @($jobRows | Where-Object { $_.job_name -eq $jn })
      if ($j.Count -gt 0) {
        $disabledOld += [ordered]@{
          job_name = $jn
          enabled = [int]$j[0].enabled
          last_status = [string]$j[0].last_status
        }
        if ([int]$j[0].enabled -eq 1) {
          # already FAIL above
        } else {
          Write-Log ("$inst old F-path job correctly disabled: $jn")
        }
      }
    }
    $ir.disabled_old_f_jobs = $disabledOld
  } catch {
    Add-Finding $report 'FAIL' 'JOBS' ("$inst job inventory failed: $($_.Exception.Message)")
    $ir.fail_findings += 'JOBS'
  }

  # 7. Recovery model
  try {
    $recFails = @()
    $recOk = @()
    for ($i = 0; $i -lt $dbs.Count; $i++) {
      $d = $dbs[$i]
      $name = [string]$d.name
      $rm = [string]$d.recovery_model_desc
      $expect = [string]$cfg.expected_recovery
      if ($cfg.simple_temp_db -and $name -eq $cfg.simple_temp_db) { $expect = 'SIMPLE' }
      if ($rm -ne $expect) {
        $recFails += [ordered]@{ name = $name; actual = $rm; expected = $expect }
      } else {
        $recOk += $name
      }
    }
    $ir.recovery = [ordered]@{ expected_default = $cfg.expected_recovery; ok = @($recOk); fail = $recFails }
    if ($recFails.Count -gt 0) {
      Add-Finding $report 'FAIL' 'RECOVERY' ("$inst recovery model mismatch: " + (($recFails | ForEach-Object { $_.name + '=' + $_.actual + '(want ' + $_.expected + ')' }) -join '; '))
      $ir.fail_findings += 'RECOVERY'
    }
  } catch {
    Add-Finding $report 'FAIL' 'RECOVERY' ("$inst recovery check failed: $($_.Exception.Message)")
    $ir.fail_findings += 'RECOVERY'
  }

  # 8. log_reuse_wait_desc
  $okWaits = @('NOTHING','CHECKPOINT','LOG_BACKUP','ACTIVE_TRANSACTION','ACTIVE_BACKUP_OR_RESTORE','XTP_CHECKPOINT','REPLICA_ROLE_TRANSITION')
  # For DEV/TST SIMPLE, LOG_BACKUP is suspicious; for PRI LOG_BACKUP is OK briefly
  $badReuse = @()
  for ($i = 0; $i -lt $dbs.Count; $i++) {
    $d = $dbs[$i]
    $w = [string]$d.log_reuse_wait_desc
    $name = [string]$d.name
    if ([string]::IsNullOrWhiteSpace($w)) { continue }
    if ($inst -in @('DEV','TST') -and $w -eq 'LOG_BACKUP') {
      $badReuse += [ordered]@{ name = $name; wait = $w; note = 'SIMPLE instance should not wait on LOG_BACKUP' }
      continue
    }
    if ($w -notin $okWaits -and $w -ne 'NOTHING') {
      # Flag sticky/unusual waits loudly
      if ($w -in @('DATABASE_MIRRORING','REPLICATION','AVAILABILITY_REPLICA','AUDIT','OLDEST_PAGE','OTHER_TRANSIENT')) {
        $badReuse += [ordered]@{ name = $name; wait = $w; note = 'unusual/stuck-prone wait' }
      }
    }
  }
  $ir.log_reuse = [ordered]@{
    snapshot = @($dbs | ForEach-Object { [ordered]@{ name = $_.name; wait = $_.log_reuse_wait_desc; recovery = $_.recovery_model_desc } })
    flagged = $badReuse
  }
  if ($badReuse.Count -gt 0) {
    Add-Finding $report 'FAIL' 'LOG_REUSE' ("$inst log_reuse flagged: " + (($badReuse | ForEach-Object { $_.name + '=' + $_.wait }) -join '; '))
    $ir.fail_findings += 'LOG_REUSE'
  }

  # 9. Smoke backup via Agent job
  $smoke = [ordered]@{
    job = $cfg.smoke_job
    started_at = $null
    outcome = $null
    g_new_files = $null
    f_new_files = $null
    secondary_tsql = $null
  }
  $smokeStart = Get-Date
  $smoke.started_at = $smokeStart.ToString('o')
  try {
    $escJob = $cfg.smoke_job -replace "'","''"
    Invoke-SqlNonQuery -Instance $inst -Query "EXEC msdb.dbo.sp_start_job @job_name = N'$escJob';" -TimeoutSec 60
    Write-Log ("$inst started smoke job $($cfg.smoke_job); waiting up to ${SmokeWaitSeconds}s")
    $outcome = Wait-JobOutcome -Instance $inst -JobName $cfg.smoke_job -StartedAfter $smokeStart -MaxSeconds $SmokeWaitSeconds
    $smoke.outcome = $outcome
    if ($outcome.run_status -ne 'Succeeded') {
      Add-Finding $report 'FAIL' 'SMOKE_JOB' ("$inst smoke job $($cfg.smoke_job) status=$($outcome.run_status): $($outcome.message)")
      $ir.fail_findings += 'SMOKE_JOB'
      # Secondary evidence: single-DB backup to G:
      try {
        $pick = $null
        for ($i = 0; $i -lt $dbs.Count; $i++) {
          if ([string]$dbs[$i].state_desc -eq 'ONLINE') { $pick = [string]$dbs[$i].name; break }
        }
        if ($pick) {
          $safe = $pick -replace '[^\w\-]', '_'
          $destLocal = Join-Path $cfg.backup_root ("__smoke_{0}_{1}.bak" -f $safe, $stamp)
          if ($inst -eq 'PRI' -and $cfg.smoke_ext -eq '*.trn') {
            $destLocal = Join-Path $cfg.backup_root ("__smoke_{0}_{1}.trn" -f $safe, $stamp)
            $tq = "BACKUP LOG [$($pick -replace ']',']]')] TO DISK = N'$($destLocal -replace "'","''")' WITH COMPRESSION, CHECKSUM, INIT;"
          } else {
            $tq = "BACKUP DATABASE [$($pick -replace ']',']]')] TO DISK = N'$($destLocal -replace "'","''")' WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, INIT;"
            # If DIFF fails (no full base), try full
          }
          try {
            Invoke-SqlNonQuery -Instance $inst -Query $tq -TimeoutSec 1800
            $smoke.secondary_tsql = [ordered]@{ ok = $true; database = $pick; path = $destLocal }
            Write-Log ("$inst secondary T-SQL backup OK: $destLocal")
          } catch {
            if ($inst -ne 'PRI') {
              $destLocal2 = Join-Path $cfg.backup_root ("__smoke_full_{0}_{1}.bak" -f $safe, $stamp)
              $tq2 = "BACKUP DATABASE [$($pick -replace ']',']]')] TO DISK = N'$($destLocal2 -replace "'","''")' WITH COMPRESSION, CHECKSUM, INIT;"
              Invoke-SqlNonQuery -Instance $inst -Query $tq2 -TimeoutSec 1800
              $smoke.secondary_tsql = [ordered]@{ ok = $true; database = $pick; path = $destLocal2; note = 'DIFF failed; FULL used' }
            } else {
              throw
            }
          }
        }
      } catch {
        $smoke.secondary_tsql = [ordered]@{ ok = $false; error = $_.Exception.Message }
        Add-Finding $report 'FAIL' 'SMOKE_TSQL' ("$inst secondary T-SQL backup also failed: $($_.Exception.Message)")
        $ir.fail_findings += 'SMOKE_TSQL'
      }
    } else {
      Write-Log ("$inst smoke job Succeeded")
    }
  } catch {
    $smoke.outcome = [ordered]@{ run_status = 'Error'; message = $_.Exception.Message }
    Add-Finding $report 'FAIL' 'SMOKE_JOB' ("$inst could not start/wait smoke job: $($_.Exception.Message)")
    $ir.fail_findings += 'SMOKE_JOB'
  }

  # Confirm G: fresh files; no F: new files
  $gFiles = Get-NewestFiles -LocalPath $cfg.backup_root -Filter $cfg.smoke_ext -Since $smokeStart.AddMinutes(-1)
  $fFiles = Get-NewestFiles -LocalPath $cfg.old_f_backup -Filter $cfg.smoke_ext -Since $smokeStart.AddMinutes(-1)
  # Also check any files under F: prefix Backup
  $smoke.g_new_files = $gFiles
  $smoke.f_new_files = $fFiles
  $freshOk = $false
  if ($gFiles.exists -and $gFiles.newest.Count -gt 0) {
    $age = [double]$gFiles.newest[0].age_minutes
    if ($age -le $FreshMinutes) { $freshOk = $true }
  }
  if ($smoke.outcome -and $smoke.outcome.run_status -eq 'Succeeded' -and -not $freshOk) {
    Add-Finding $report 'FAIL' 'SMOKE_G_FRESH' ("$inst smoke Succeeded but no fresh $($cfg.smoke_ext) under G: within ${FreshMinutes}m")
    $ir.fail_findings += 'SMOKE_G_FRESH'
  }
  if ($fFiles.exists -and $fFiles.new_since_count -gt 0) {
    Add-Finding $report 'FAIL' 'SMOKE_F_WRITE' ("$inst NEW backup files written under F: during smoke ($($fFiles.new_since_count))")
    $ir.fail_findings += 'SMOKE_F_WRITE'
  }
  $ir.smoke = $smoke

  # 10. RESTORE VERIFYONLY
  $verify = [ordered]@{ bak = $null; trn = $null }
  try {
    $gUnc = Convert-DriveToUnc $cfg.backup_root
    $bakCandidates = @()
    if (Test-Path -LiteralPath $gUnc) {
      $bakCandidates = @(Get-ChildItem -LiteralPath $gUnc -Filter '*.bak' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object Length, LastWriteTime -Descending |
        Sort-Object Length |
        Select-Object -First 30)
      # Prefer smaller recent files
      $bakCandidates = @($bakCandidates | Sort-Object Length | Select-Object -First 15)
    }
    $chosen = $null
    if ($bakCandidates.Count -gt 0) {
      # Prefer smallest under 2GB that is recent if possible
      $chosen = $bakCandidates[0]
      foreach ($c in $bakCandidates) {
        if ($c.Length -lt 2GB) { $chosen = $c; break }
      }
    }
    if ($chosen) {
      # Map UNC back to local path for SQL on host
      $diskPath = $chosen.FullName -replace ('^\\\\' + [regex]::Escape($SqlHost) + '\\([A-Za-z])\$'), '${1}:'
      $escPath = $diskPath -replace "'","''"
      try {
        Invoke-SqlNonQuery -Instance $inst -Query "RESTORE VERIFYONLY FROM DISK = N'$escPath' WITH CHECKSUM;" -TimeoutSec 1800
        $verify.bak = [ordered]@{ path = $diskPath; size_bytes = $chosen.Length; ok = $true }
        Write-Log ("$inst RESTORE VERIFYONLY OK: $diskPath")
      } catch {
        $verify.bak = [ordered]@{ path = $diskPath; size_bytes = $chosen.Length; ok = $false; error = $_.Exception.Message }
        Add-Finding $report 'FAIL' 'VERIFYONLY' ("$inst RESTORE VERIFYONLY failed for $diskPath : $($_.Exception.Message)")
        $ir.fail_findings += 'VERIFYONLY'
      }
    } else {
      Add-Finding $report 'FAIL' 'VERIFYONLY' ("$inst no .bak found under $($cfg.backup_root) for VERIFYONLY")
      $ir.fail_findings += 'VERIFYONLY'
      $verify.bak = [ordered]@{ ok = $false; error = 'no .bak found' }
    }

    if ($inst -eq 'PRI') {
      $trnList = @()
      if (Test-Path -LiteralPath $gUnc) {
        $trnList = @(Get-ChildItem -LiteralPath $gUnc -Filter '*.trn' -File -Recurse -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 5)
      }
      if ($trnList.Count -gt 0) {
        $t = $trnList[0]
        $tPath = $t.FullName -replace ('^\\\\' + [regex]::Escape($SqlHost) + '\\([A-Za-z])\$'), '${1}:'
        $escT = $tPath -replace "'","''"
        try {
          Invoke-SqlNonQuery -Instance $inst -Query "RESTORE VERIFYONLY FROM DISK = N'$escT';" -TimeoutSec 600
          $verify.trn = [ordered]@{ path = $tPath; ok = $true }
          Write-Log ("$inst RESTORE VERIFYONLY .trn OK: $tPath")
        } catch {
          # Chain may be required - record as WARN not automatic FAIL if bak verify OK
          $verify.trn = [ordered]@{ path = $tPath; ok = $false; error = $_.Exception.Message; note = 'trn verify may need chain; bak verify preferred' }
          Write-Log ("$inst .trn VERIFYONLY skipped/failed (non-fatal if bak OK): $($_.Exception.Message)") 'WARN'
        }
      } else {
        $verify.trn = [ordered]@{ ok = $false; note = 'no .trn found; skipped' }
      }
    }
  } catch {
    Add-Finding $report 'FAIL' 'VERIFYONLY' ("$inst VERIFYONLY section error: $($_.Exception.Message)")
    $ir.fail_findings += 'VERIFYONLY'
  }
  $ir.verifyonly = $verify

  $report.instances += $ir
}

# Finalize
$report.finished_local = (Get-Date).ToString('o')
if ($report.fail_count -gt 0) { $report.overall = 'FAIL' } else { $report.overall = 'PASS' }

$json = ($report | ConvertTo-Json -Depth 10)
Set-Content -LiteralPath $OutJson -Value $json -Encoding UTF8

# Short txt summary
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("MSSQL post-move backup health - $($report.overall)")
[void]$sb.AppendLine("Collected: $($report.started_local) -> $($report.finished_local)")
[void]$sb.AppendLine("Collector: $($report.collector) -> host $($report.host)")
[void]$sb.AppendLine("FAIL count: $($report.fail_count)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Instance | SQL+Agent | BackupDirectory | Smoke | VERIFYONLY | FAILs")
[void]$sb.AppendLine("---------|-----------|-----------------|-------|------------|------")
foreach ($ir in @($report.instances)) {
  $svcOk = ($ir.services.sql.ok -and $ir.services.agent.ok)
  $bd = if ($ir.backup_directory) { $ir.backup_directory.value } else { 'n/a' }
  $sm = if ($ir.smoke -and $ir.smoke.outcome) { $ir.smoke.outcome.run_status } else { 'n/a' }
  $vo = if ($ir.verifyonly -and $ir.verifyonly.bak) { $(if ($ir.verifyonly.bak.ok) { 'OK' } else { 'FAIL' }) } else { 'n/a' }
  $ff = ($ir.fail_findings -join ',')
  if (-not $ff) { $ff = '-' }
  [void]$sb.AppendLine(("{0} | {1} | {2} | {3} | {4} | {5}" -f $ir.instance, $(if ($svcOk) {'UP'} else {'DOWN'}), $bd, $sm, $vo, $ff))
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine('Findings:')
foreach ($f in @($report.findings)) {
  [void]$sb.AppendLine(("  [{0}] {1}: {2}" -f $f.severity, $f.code, $f.message))
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Archive: $($report.archive.path) exists=$($report.archive.exists)")
foreach ($af in @($report.archive.folders)) {
  [void]$sb.AppendLine(("  {0}: exists={1} files={2} (expected~{3})" -f $af.name, $af.exists, $af.file_count, $af.expected_approx))
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine('Disk free (F/G/I):')
foreach ($v in @($report.disk.volumes)) {
  [void]$sb.AppendLine(("  {0} ({1}): free {2} GB / {3} GB ({4}%)" -f $v.name, $v.label, $v.free_gb, $v.capacity_gb, $v.free_pct))
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("JSON: $OutJson")
[void]$sb.AppendLine("Suggested human-equivalent DBA hours: $($report.suggested_human_hours)")
Set-Content -LiteralPath $OutTxt -Value $sb.ToString() -Encoding UTF8

Write-Log "Wrote $OutJson"
Write-Log "Wrote $OutTxt"
Write-Log "OVERALL $($report.overall) fail_count=$($report.fail_count)"
Write-Output ("RESULT={0}; JSON={1}; TXT={2}" -f $report.overall, $OutJson, $OutTxt)
