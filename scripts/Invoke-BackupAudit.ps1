#Requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY MSSQL backup audit for configured named instances.
  SqlHost, Instances, and OutRoot are supplied by the catalog wrapper from instances.json.
  Does NOT alter jobs, plans, databases, or delete any backup files.
  Volume heuristics in the gap report still flag F: as a data volume and G:/H: as backup volumes; treat drive letters as deployment config, not a universal standard.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SqlHost,
  [Parameter(Mandatory = $true)]
  [string[]]$Instances,
  [Parameter(Mandatory = $true)]
  [string]$OutRoot,
  [string[]]$MountPaths = @(),
  [int]$HistoryDays = 14
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
$utcStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'

New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutRoot 'raw') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutRoot 'per-instance') | Out-Null

function Write-SectionFile {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -Path $Path -Value $Content -Encoding UTF8
}

function Invoke-SqlText {
  param(
    [string]$Instance,
    [string]$Database = 'master',
    [string]$Query,
    [int]$QueryTimeout = 120
  )
  $server = if ($Instance) { "$SqlHost\$Instance" } else { $SqlHost }
  $cs = "Server=$server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=30;"
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $Query
  $cmd.CommandTimeout = $QueryTimeout
  $dt = New-Object System.Data.DataTable
  try {
    $conn.Open()
    $rdr = $cmd.ExecuteReader()
    $dt.Load($rdr)
    $rdr.Close()
  } catch {
    $err = $_.Exception.Message
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('ERROR')
    $row = $dt.NewRow(); $row['ERROR'] = $err; [void]$dt.Rows.Add($row)
  } finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $conn.Dispose()
  }
  return $dt
}

function Convert-DataTableToTsv {
  param([System.Data.DataTable]$Table)
  if (-not $Table -or $Table.Columns.Count -eq 0) { return '(empty)' }
  $cols = @($Table.Columns | ForEach-Object { $_.ColumnName })
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine(($cols -join "`t"))
  foreach ($row in $Table.Rows) {
    $vals = foreach ($c in $cols) {
      $v = $row[$c]
      if ($null -eq $v -or $v -is [DBNull]) { '' } else { ([string]$v) -replace "`t",' ' -replace "`r|`n",' ' }
    }
    [void]$sb.AppendLine(($vals -join "`t"))
  }
  return $sb.ToString()
}

function Format-BytesGB {
  param([long]$Bytes)
  if ($null -eq $Bytes) { return 'n/a' }
  return ('{0:N2}' -f ($Bytes / 1GB))
}

# ---------- A) Host disk / mount points ----------
# MountPaths optional (from instances.json dbaInstances data/log paths). Falls back to CIM on sqlHost only.

$diskReport = New-Object System.Text.StringBuilder
[void]$diskReport.AppendLine("# Disk / volume audit")
[void]$diskReport.AppendLine("Collected: $stamp ($utcStamp)")
[void]$diskReport.AppendLine("Collector host: $env:COMPUTERNAME / $env:USERDOMAIN\$env:USERNAME")
[void]$diskReport.AppendLine("")

$targetPaths = @($MountPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

# Try remote Win32_Volume / Win32_LogicalDisk on SQL host
$remoteHost = $SqlHost
[void]$diskReport.AppendLine("## Attempt: CIM Win32_Volume on $remoteHost")
try {
  $vols = Get-CimInstance -ComputerName $remoteHost -ClassName Win32_Volume -ErrorAction Stop |
    Select-Object Name, Label, DriveLetter, FileSystem, Capacity, FreeSpace, @{N='FreePct';E={ if ($_.Capacity) { [math]::Round(100.0*$_.FreeSpace/$_.Capacity,2) } else { $null } }}, @{N='CapacityGB';E={ if ($_.Capacity) { [math]::Round($_.Capacity/1GB,2) } }}, @{N='FreeGB';E={ if ($_.FreeSpace -ne $null) { [math]::Round($_.FreeSpace/1GB,2) } }}
  $volTsv = ($vols | ConvertTo-Csv -NoTypeInformation -Delimiter "`t") -join "`n"
  [void]$diskReport.AppendLine('```')
  [void]$diskReport.AppendLine($volTsv)
  [void]$diskReport.AppendLine('```')
  $vols | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutRoot 'raw\host_win32_volume.json') -Encoding UTF8
} catch {
  [void]$diskReport.AppendLine("CIM Win32_Volume FAILED: $($_.Exception.Message)")
}

[void]$diskReport.AppendLine("")
[void]$diskReport.AppendLine("## Attempt: CIM Win32_LogicalDisk on $remoteHost")
try {
  $ld = Get-CimInstance -ComputerName $remoteHost -ClassName Win32_LogicalDisk -ErrorAction Stop |
    Select-Object DeviceID, VolumeName, FileSystem, Size, FreeSpace, @{N='FreePct';E={ if ($_.Size) { [math]::Round(100.0*$_.FreeSpace/$_.Size,2) } else { $null } }}, @{N='SizeGB';E={ if ($_.Size) { [math]::Round($_.Size/1GB,2) } }}, @{N='FreeGB';E={ if ($_.FreeSpace -ne $null) { [math]::Round($_.FreeSpace/1GB,2) } }}
  [void]$diskReport.AppendLine('```')
  [void]$diskReport.AppendLine((($ld | ConvertTo-Csv -NoTypeInformation -Delimiter "`t") -join "`n"))
  [void]$diskReport.AppendLine('```')
  $ld | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutRoot 'raw\host_win32_logicaldisk.json') -Encoding UTF8
} catch {
  [void]$diskReport.AppendLine("CIM Win32_LogicalDisk FAILED: $($_.Exception.Message)")
}

# Also try local Get-Volume in case DEV1 somehow has them (unlikely)
[void]$diskReport.AppendLine("")
[void]$diskReport.AppendLine("## Local Get-Volume (collector)")
try {
  $gv = Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, Path, Size, SizeRemaining, @{N='FreePct';E={ if ($_.Size) { [math]::Round(100.0*$_.SizeRemaining/$_.Size,2) } else { $null } }}, @{N='SizeGB';E={ if ($_.Size) { [math]::Round($_.Size/1GB,2) } }}, @{N='FreeGB';E={ if ($_.SizeRemaining -ne $null) { [math]::Round($_.SizeRemaining/1GB,2) } }}
  [void]$diskReport.AppendLine('```')
  [void]$diskReport.AppendLine((($gv | ConvertTo-Csv -NoTypeInformation -Delimiter "`t") -join "`n"))
  [void]$diskReport.AppendLine('```')
} catch {
  [void]$diskReport.AppendLine("Get-Volume FAILED: $($_.Exception.Message)")
}

# Probe path existence / size via remote admin shares if possible
[void]$diskReport.AppendLine("")
[void]$diskReport.AppendLine("## Path probes (remote admin shares / direct)")
$pathProbe = @()
foreach ($p in $targetPaths) {
  $drive = $p.Substring(0,1)
  $rest = if ($p.Length -gt 3) { $p.Substring(3) } else { '' }
  $uncCandidates = @(
    $p,
    ("\\{0}\{1}`${2}" -f $remoteHost, $drive, $(if ($rest) { '\' + $rest } else { '' }))
  )
  foreach ($cand in $uncCandidates) {
    $exists = Test-Path -LiteralPath $cand -ErrorAction SilentlyContinue
    $entry = [ordered]@{ Path = $cand; Exists = [bool]$exists; Note = '' }
    if ($exists) {
      try {
        $item = Get-Item -LiteralPath $cand -ErrorAction Stop
        $entry.Note = "Exists; Attributes=$($item.Attributes)"
      } catch { $entry.Note = $_.Exception.Message }
    }
    $pathProbe += [pscustomobject]$entry
  }
}
[void]$diskReport.AppendLine('```')
[void]$diskReport.AppendLine((($pathProbe | ConvertTo-Csv -NoTypeInformation -Delimiter "`t") -join "`n"))
[void]$diskReport.AppendLine('```')

Write-SectionFile (Join-Path $OutRoot '00_disk_volumes.md') $diskReport.ToString()

# ---------- Per-instance SQL collection ----------
$allGapRows = @()
$jobMatrix = @()
$destMatrix = @()
$critAlerts = @()
$summaryParts = @()

$sqlDatabases = @'
SET NOCOUNT ON;
SELECT
  d.name,
  d.recovery_model_desc,
  d.state_desc,
  d.log_reuse_wait_desc,
  CAST(SUM(CASE WHEN mf.type_desc = 'LOG' THEN mf.size ELSE 0 END) * 8.0 / 1024 AS decimal(18,2)) AS log_size_mb,
  CAST(SUM(CASE WHEN mf.type_desc = 'ROWS' THEN mf.size ELSE 0 END) * 8.0 / 1024 AS decimal(18,2)) AS data_size_mb
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
GROUP BY d.name, d.recovery_model_desc, d.state_desc, d.log_reuse_wait_desc
ORDER BY d.name;
'@

$sqlMasterFiles = @'
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS db_name, name AS logical_name, type_desc, physical_name,
  CAST(size * 8.0 / 1024 AS decimal(18,2)) AS size_mb,
  state_desc
FROM sys.master_files
ORDER BY DB_NAME(database_id), type_desc, name;
'@

$sqlBackupDir = @'
SET NOCOUNT ON;
DECLARE @BackupDirectory nvarchar(512) = NULL;
BEGIN TRY
  EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'BackupDirectory',
    @BackupDirectory OUTPUT;
END TRY BEGIN CATCH
  SET @BackupDirectory = NULL;
END CATCH
SELECT
  @@SERVERNAME AS server_name,
  CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS instance_name,
  CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
  @BackupDirectory AS BackupDirectory,
  CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS DefaultDataPath,
  CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(512)) AS DefaultLogPath;
'@

$sqlVolumeStats = @'
SET NOCOUNT ON;
;WITH vols AS (
  SELECT DISTINCT
    vs.volume_mount_point,
    vs.logical_volume_name,
    vs.file_system_type,
    vs.total_bytes,
    vs.available_bytes
  FROM sys.master_files mf
  CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
)
SELECT
  volume_mount_point,
  logical_volume_name,
  file_system_type,
  CAST(total_bytes/1024.0/1024/1024 AS decimal(18,2)) AS total_gb,
  CAST(available_bytes/1024.0/1024/1024 AS decimal(18,2)) AS free_gb,
  CAST(100.0*available_bytes/NULLIF(total_bytes,0) AS decimal(5,2)) AS free_pct
FROM vols
ORDER BY volume_mount_point;
'@

$sqlJobs = @'
SET NOCOUNT ON;
SELECT
  j.job_id,
  j.name AS job_name,
  c.name AS category,
  j.enabled,
  j.date_created,
  j.date_modified,
  CASE jh.run_status
    WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 2 THEN 'Retry'
    WHEN 3 THEN 'Canceled' WHEN 4 THEN 'InProgress' ELSE CAST(jh.run_status AS varchar(10))
  END AS last_run_outcome,
  jh.run_date AS last_run_date,
  jh.run_time AS last_run_time,
  jh.run_duration AS last_run_duration,
  ja.next_run_date,
  ja.next_run_time,
  s.name AS schedule_name,
  s.enabled AS schedule_enabled,
  s.freq_type,
  s.freq_interval,
  s.freq_subday_type,
  s.freq_subday_interval,
  s.freq_recurrence_factor,
  s.active_start_time,
  s.active_end_time,
  CASE s.freq_type
    WHEN 1 THEN 'OneTime'
    WHEN 4 THEN 'Daily'
    WHEN 8 THEN 'Weekly'
    WHEN 16 THEN 'Monthly'
    WHEN 32 THEN 'MonthlyRel'
    WHEN 64 THEN 'AgentStart'
    WHEN 128 THEN 'Idle'
    ELSE CAST(s.freq_type AS varchar(10))
  END AS freq_type_desc,
  CASE s.freq_subday_type
    WHEN 1 THEN 'AtTime'
    WHEN 2 THEN 'Seconds'
    WHEN 4 THEN 'Minutes'
    WHEN 8 THEN 'Hours'
    ELSE CAST(s.freq_subday_type AS varchar(10))
  END AS freq_subday_desc
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysjobactivity ja ON ja.job_id = j.job_id
  AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
OUTER APPLY (
  SELECT TOP 1 * FROM msdb.dbo.sysjobhistory h
  WHERE h.job_id = j.job_id AND h.step_id = 0
  ORDER BY h.instance_id DESC
) jh
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
WHERE
  j.name LIKE '%backup%' OR j.name LIKE '%Backup%'
  OR j.name LIKE '%maint%' OR j.name LIKE '%Maint%'
  OR j.name LIKE '%Maintenance%' OR j.name LIKE '%maintenance%'
  OR c.name LIKE '%Database Maintenance%'
  OR c.name LIKE '%Backup%'
ORDER BY j.name, s.name;
'@

$sqlJobSteps = @'
SET NOCOUNT ON;
SELECT
  j.name AS job_name,
  j.enabled AS job_enabled,
  js.step_id,
  js.step_name,
  js.subsystem,
  js.command,
  js.database_name,
  js.on_success_action,
  js.on_fail_action
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE
  j.name LIKE '%backup%' OR j.name LIKE '%Backup%'
  OR j.name LIKE '%maint%' OR j.name LIKE '%Maint%'
  OR j.name LIKE '%Maintenance%' OR j.name LIKE '%maintenance%'
  OR js.command LIKE '%BACKUP %' OR js.command LIKE '%backup %'
  OR js.command LIKE '%xp_delete_file%' OR js.command LIKE '%Maintenance%'
ORDER BY j.name, js.step_id;
'@

$sqlMaintPlans = @'
SET NOCOUNT ON;
IF OBJECT_ID('msdb.dbo.sysmaintplan_plans') IS NULL
BEGIN
  SELECT 'sysmaintplan_plans not present' AS note;
END
ELSE
BEGIN
  SELECT
    p.name AS plan_name,
    p.id AS plan_id,
    p.description,
    p.create_date,
    sp.subplan_name,
    sp.subplan_id,
    j.name AS job_name,
    j.enabled AS job_enabled,
    s.name AS schedule_name,
    s.enabled AS schedule_enabled,
    s.freq_type,
    s.freq_interval,
    s.freq_subday_type,
    s.freq_subday_interval,
    CASE s.freq_type
      WHEN 1 THEN 'OneTime' WHEN 4 THEN 'Daily' WHEN 8 THEN 'Weekly'
      WHEN 16 THEN 'Monthly' ELSE CAST(s.freq_type AS varchar(10))
    END AS freq_type_desc
  FROM msdb.dbo.sysmaintplan_plans p
  LEFT JOIN msdb.dbo.sysmaintplan_subplans sp ON sp.plan_id = p.id
  LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
  LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
  LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
  ORDER BY p.name, sp.subplan_name;
END
'@

$sqlSsisPackages = @'
SET NOCOUNT ON;
IF OBJECT_ID('msdb.dbo.sysssispackages') IS NULL
BEGIN
  SELECT 'sysssispackages not present' AS note;
END
ELSE
BEGIN
  SELECT
    name,
    id,
    description,
    createdate,
    folderid,
    packagetype,
    CASE WHEN CAST(packagedata AS varbinary(max)) IS NULL THEN 0 ELSE DATALENGTH(packagedata) END AS package_bytes
  FROM msdb.dbo.sysssispackages
  WHERE name LIKE '%Maint%' OR name LIKE '%Backup%' OR name LIKE '%backup%' OR name LIKE '%Maintenance%'
  ORDER BY name;
END
'@

$sqlSsisPackagePaths = @'
SET NOCOUNT ON;
IF OBJECT_ID('msdb.dbo.sysssispackages') IS NULL
BEGIN
  SELECT 'sysssispackages not present' AS note;
END
ELSE
BEGIN
  ;WITH pkgs AS (
    SELECT name, CAST(CAST(packagedata AS varbinary(max)) AS xml) AS px
    FROM msdb.dbo.sysssispackages
    WHERE name LIKE '%Maint%' OR name LIKE '%Backup%' OR name LIKE '%backup%' OR name LIKE '%Maintenance%'
  )
  SELECT
    name AS package_name,
    T.N.value('.','nvarchar(max)') AS xml_path_hint
  FROM pkgs
  CROSS APPLY px.nodes('//*[contains(local-name(),''Path'') or contains(local-name(),''Folder'') or contains(local-name(),''Directory'') or contains(.,''Backup'') or contains(.,'':\\'')]') AS T(N)
END
'@

# Simpler package text extract for paths (handles non-xml packagedata)
$sqlSsisPackageText = @'
SET NOCOUNT ON;
IF OBJECT_ID('msdb.dbo.sysssispackages') IS NULL
BEGIN
  SELECT 'sysssispackages not present' AS note;
END
ELSE
BEGIN
  SELECT
    name AS package_name,
    CAST(CAST(packagedata AS varbinary(max)) AS varchar(max)) AS package_text_sample
  FROM msdb.dbo.sysssispackages
  WHERE name LIKE '%Maint%' OR name LIKE '%Backup%' OR name LIKE '%backup%' OR name LIKE '%Maintenance%';
END
'@

$sqlBackupHistory = @"
SET NOCOUNT ON;
DECLARE @since datetime = DATEADD(day, -$HistoryDays, GETDATE());

;WITH bak AS (
  SELECT
    bs.database_name,
    bs.type,
    CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE bs.type END AS backup_type,
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.is_copy_only,
    bs.has_backup_checksums,
    bs.compressed_backup_size,
    bs.backup_size,
    bmf.physical_device_name,
    bs.is_damaged,
    CASE WHEN bs.is_damaged = 1 THEN 1 ELSE 0 END AS failed_flag
  FROM msdb.dbo.backupset bs
  LEFT JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
  WHERE bs.backup_start_date >= @since
)
SELECT * INTO #bak FROM bak;

-- Latest per type
SELECT database_name, backup_type,
  MAX(backup_finish_date) AS latest_success,
  COUNT(*) AS backup_count
FROM #bak
GROUP BY database_name, backup_type
ORDER BY database_name, backup_type;

-- Distinct roots
SELECT database_name, backup_type,
  LEFT(physical_device_name, CASE WHEN CHARINDEX('\', physical_device_name, 4) > 0
    THEN CHARINDEX('\', physical_device_name, 4) ELSE LEN(physical_device_name) END) AS path_root,
  COUNT(*) AS cnt,
  MIN(physical_device_name) AS sample_path
FROM #bak
WHERE physical_device_name IS NOT NULL
GROUP BY database_name, backup_type,
  LEFT(physical_device_name, CASE WHEN CHARINDEX('\', physical_device_name, 4) > 0
    THEN CHARINDEX('\', physical_device_name, 4) ELSE LEN(physical_device_name) END)
ORDER BY database_name, backup_type, path_root;

-- Gap flags
SELECT
  d.name AS database_name,
  d.recovery_model_desc,
  (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'FULL') AS last_full,
  (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'DIFF') AS last_diff,
  (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'LOG') AS last_log,
  (SELECT COUNT(*) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'DIFF') AS diff_count_14d,
  (SELECT COUNT(*) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'LOG') AS log_count_14d,
  (SELECT COUNT(*) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'FULL') AS full_count_14d,
  CASE WHEN d.recovery_model_desc = 'FULL'
    AND (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'LOG') < DATEADD(hour, -24, GETDATE())
    THEN 1 WHEN d.recovery_model_desc = 'FULL'
    AND (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'LOG') IS NULL
    THEN 1 ELSE 0 END AS gap_no_log_24h,
  CASE WHEN (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'FULL') < DATEADD(day, -8, GETDATE())
    OR (SELECT MAX(backup_finish_date) FROM #bak b WHERE b.database_name = d.name AND b.backup_type = 'FULL') IS NULL
    THEN 1 ELSE 0 END AS gap_no_full_8d
FROM sys.databases d
WHERE d.name NOT IN ('tempdb')
ORDER BY d.name;

DROP TABLE #bak;
"@

$sqlBackupFailures = @"
SET NOCOUNT ON;
DECLARE @since datetime = DATEADD(day, -$HistoryDays, GETDATE());
-- Job failures related to backup (from job history)
SELECT
  j.name AS job_name,
  h.step_id,
  h.step_name,
  h.run_date,
  h.run_time,
  h.run_status,
  LEFT(h.message, 500) AS message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.run_date >= CONVERT(int, CONVERT(varchar(8), @since, 112))
  AND h.run_status = 0
  AND (j.name LIKE '%backup%' OR j.name LIKE '%Backup%' OR j.name LIKE '%Maint%' OR j.name LIKE '%maint%'
       OR j.name LIKE '%Maintenance%' OR h.message LIKE '%BACKUP%')
ORDER BY h.run_date DESC, h.run_time DESC;
"@

foreach ($inst in $Instances) {
  Write-Host "=== Auditing $SqlHost\$inst ===" -ForegroundColor Cyan
  $instDir = Join-Path $OutRoot "per-instance\$inst"
  New-Item -ItemType Directory -Force -Path $instDir | Out-Null
  $md = New-Object System.Text.StringBuilder
  [void]$md.AppendLine("# Instance $SqlHost\$inst")
  [void]$md.AppendLine("Collected: $stamp")
  [void]$md.AppendLine("")

  # Header / backup directory
  $hdr = Invoke-SqlText -Instance $inst -Query $sqlBackupDir
  Write-SectionFile (Join-Path $instDir 'A_backup_directory.tsv') (Convert-DataTableToTsv $hdr)
  [void]$md.AppendLine("## A) Default BackupDirectory / paths")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $hdr))
  [void]$md.AppendLine('```')

  $backupDir = $null
  if ($hdr.Columns.Contains('BackupDirectory') -and $hdr.Rows.Count -gt 0 -and $hdr.Rows[0]['BackupDirectory'] -isnot [DBNull]) {
    $backupDir = [string]$hdr.Rows[0]['BackupDirectory']
  }

  # Volume stats via SQL
  $vols = Invoke-SqlText -Instance $inst -Query $sqlVolumeStats
  Write-SectionFile (Join-Path $instDir 'A_volume_stats.tsv') (Convert-DataTableToTsv $vols)
  [void]$md.AppendLine("## A) Volumes via sys.dm_os_volume_stats")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $vols))
  [void]$md.AppendLine('```')

  foreach ($r in $vols.Rows) {
    if ($r.Table.Columns.Contains('ERROR')) { continue }
    $mp = [string]$r['volume_mount_point']
    $freePct = $r['free_pct']
    $freeGb = $r['free_gb']
    if ($freePct -ne [DBNull]::Value -and [double]$freePct -lt 5) {
      $critAlerts += [pscustomobject]@{ Instance=$inst; Alert="CRITICAL free space $mp free_pct=$freePct free_gb=$freeGb" }
    }
    elseif ($freePct -ne [DBNull]::Value -and [double]$freePct -lt 10) {
      $critAlerts += [pscustomobject]@{ Instance=$inst; Alert="WARN low free space $mp free_pct=$freePct free_gb=$freeGb" }
    }
  }

  # Master files
  $mf = Invoke-SqlText -Instance $inst -Query $sqlMasterFiles
  Write-SectionFile (Join-Path $instDir 'A_master_files.tsv') (Convert-DataTableToTsv $mf)
  [void]$md.AppendLine("## A) sys.master_files (data/log locations)")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $mf))
  [void]$md.AppendLine('```')

  # Backup folder listing + sizes
  [void]$md.AppendLine("## A) Backup folders on disk")
  $candidateBackupRoots = @()
  if ($backupDir) { $candidateBackupRoots += $backupDir }
  foreach ($mp in @($MountPaths)) {
    if ([string]::IsNullOrWhiteSpace($mp)) { continue }
    $candidateBackupRoots += @(
      (Join-Path $mp 'Backup'),
      (Join-Path $mp 'Backups'),
      (Join-Path $mp 'MSSQL\Backup')
    )
  }
  $candidateBackupRoots += @('H:\Backup', 'H:\Backups')
  $candidateBackupRoots = $candidateBackupRoots | Select-Object -Unique

  $folderLines = @()
  foreach ($root in $candidateBackupRoots) {
    $unc = $root
    # Try remote admin share form
    if ($root -match '^([A-Za-z]):\\(.*)$') {
      $uncAlt = "\\$remoteHost\$($Matches[1])`$\$($Matches[2])"
    } else { $uncAlt = $null }

    foreach ($tryPath in @($root, $uncAlt) | Where-Object { $_ }) {
      if (-not (Test-Path -LiteralPath $tryPath -ErrorAction SilentlyContinue)) {
        $folderLines += "MISSING: $tryPath"
        continue
      }
      $folderLines += "FOUND: $tryPath"
      try {
        $top = Get-ChildItem -LiteralPath $tryPath -Force -ErrorAction Stop | Select-Object Name, Mode, Length, LastWriteTime
        $folderLines += "  Top-level entries: $($top.Count)"
        foreach ($t in $top | Select-Object -First 40) {
          $folderLines += ("  - {0}  {1}  {2}" -f $t.Mode, $t.Name, $t.LastWriteTime)
        }
        $files = Get-ChildItem -LiteralPath $tryPath -Recurse -File -Include *.bak,*.trn,*.bak,*.TRN -ErrorAction SilentlyContinue
        # Include filter quirks: also measure separately
        $files = @(Get-ChildItem -LiteralPath $tryPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(bak|trn)$' })
        if ($files.Count -gt 0) {
          $sum = ($files | Measure-Object -Property Length -Sum).Sum
          $oldest = ($files | Sort-Object LastWriteTime | Select-Object -First 1)
          $newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
          $folderLines += ("  *.bak/*.trn count={0} total_bytes={1} total_GB={2:N2}" -f $files.Count, $sum, ($sum/1GB))
          $folderLines += ("  oldest={0} ({1})" -f $oldest.FullName, $oldest.LastWriteTime)
          $folderLines += ("  newest={0} ({1})" -f $newest.FullName, $newest.LastWriteTime)
          # sample 10 oldest / 10 newest names
          $folderLines += "  sample_oldest:"
          foreach ($f in ($files | Sort-Object LastWriteTime | Select-Object -First 10)) {
            $folderLines += ("    {0:u}  {1:N2}MB  {2}" -f $f.LastWriteTime, ($f.Length/1MB), $f.Name)
          }
          $folderLines += "  sample_newest:"
          foreach ($f in ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
            $folderLines += ("    {0:u}  {1:N2}MB  {2}" -f $f.LastWriteTime, ($f.Length/1MB), $f.Name)
          }
        } else {
          $folderLines += "  No *.bak/*.trn found under this root"
        }
      } catch {
        $folderLines += "  ERROR listing $tryPath : $($_.Exception.Message)"
      }
      break  # stop after first successful path variant
    }
  }
  [void]$md.AppendLine('```')
  [void]$md.AppendLine(($folderLines -join "`n"))
  [void]$md.AppendLine('```')
  Write-SectionFile (Join-Path $instDir 'A_backup_folders.txt') ($folderLines -join "`r`n")

  # B) Databases
  $dbs = Invoke-SqlText -Instance $inst -Query $sqlDatabases
  Write-SectionFile (Join-Path $instDir 'B_databases.tsv') (Convert-DataTableToTsv $dbs)
  [void]$md.AppendLine("## B) Databases")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $dbs))
  [void]$md.AppendLine('```')
  foreach ($r in $dbs.Rows) {
    if ($r.Table.Columns.Contains('ERROR')) { continue }
    if ([string]$r['log_reuse_wait_desc'] -eq 'LOG_BACKUP') {
      $critAlerts += [pscustomobject]@{ Instance=$inst; Alert=("DB {0} log_reuse_wait_desc=LOG_BACKUP" -f $r['name']) }
    }
  }

  # Try log used pct via DBCC / dm_db_log_space_usage for user DBs - lightweight
  $logUsedQ = @'
SET NOCOUNT ON;
CREATE TABLE #log (db sysname, log_size_mb float, log_used_pct float, status int);
INSERT INTO #log EXEC('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');
SELECT db AS database_name, log_size_mb, log_used_pct FROM #log ORDER BY log_used_pct DESC;
DROP TABLE #log;
'@
  $logUsed = Invoke-SqlText -Instance $inst -Query $logUsedQ
  Write-SectionFile (Join-Path $instDir 'B_log_space.tsv') (Convert-DataTableToTsv $logUsed)
  [void]$md.AppendLine("## B) Log space (DBCC SQLPERF)")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $logUsed))
  [void]$md.AppendLine('```')

  # C) Jobs
  $jobs = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlJobs
  Write-SectionFile (Join-Path $instDir 'C_jobs.tsv') (Convert-DataTableToTsv $jobs)
  [void]$md.AppendLine("## C) Backup/maintenance Agent jobs + schedules")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $jobs))
  [void]$md.AppendLine('```')

  $steps = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlJobSteps
  Write-SectionFile (Join-Path $instDir 'C_job_steps.tsv') (Convert-DataTableToTsv $steps)
  [void]$md.AppendLine("## C) Job steps (commands)")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $steps))
  [void]$md.AppendLine('```')

  foreach ($r in $jobs.Rows) {
    if ($r.Table.Columns.Contains('ERROR')) { break }
    $freq = ''
    if ($r.Table.Columns.Contains('freq_type_desc')) { $freq = [string]$r['freq_type_desc'] }
    $sub = ''
    if ($r.Table.Columns.Contains('freq_subday_desc')) { $sub = [string]$r['freq_subday_desc'] }
    $subInt = $r['freq_subday_interval']
    $schedHuman = $freq
    if ($sub -and $sub -ne '' -and $sub -ne 'AtTime') {
      $schedHuman = "$freq every $subInt $sub"
    }
    $jobMatrix += [pscustomobject]@{
      Instance = $inst
      Job = [string]$r['job_name']
      Enabled = $r['enabled']
      Category = [string]$r['category']
      Schedule = [string]$r['schedule_name']
      Freq = $schedHuman
      LastOutcome = [string]$r['last_run_outcome']
      LastRunDate = [string]$r['last_run_date']
      LastRunTime = [string]$r['last_run_time']
      NextRunDate = [string]$r['next_run_date']
      NextRunTime = [string]$r['next_run_time']
    }
  }

  foreach ($r in $steps.Rows) {
    if ($r.Table.Columns.Contains('ERROR')) { break }
    $cmd = [string]$r['command']
    $btype = ''
    if ($cmd -match 'BACKUP\s+DATABASE') {
      if ($cmd -match 'DIFFERENTIAL') { $btype = 'DIFF' } else { $btype = 'FULL' }
    } elseif ($cmd -match 'BACKUP\s+LOG') { $btype = 'LOG' }
    elseif ($cmd -match 'xp_delete_file') { $btype = 'CLEANUP' }
    $dest = ''
    if ($cmd -match "DISK\s*=\s*N?'([^']+)'") { $dest = $Matches[1] }
    elseif ($cmd -match 'DISK\s*=\s*"([^"]+)"') { $dest = $Matches[1] }
    elseif ($cmd -match "xp_delete_file\s*\([^,]+,\s*N?'([^']+)'") { $dest = $Matches[1] }
    $checksum = ($cmd -match 'CHECKSUM')
    $compr = ($cmd -match 'COMPRESSION')
    $onDataVol = $false
    if ($dest -match '^[Ff]:\\') { $onDataVol = $true }
    $destMatrix += [pscustomobject]@{
      Instance = $inst
      Job = [string]$r['job_name']
      Step = [string]$r['step_name']
      Subsystem = [string]$r['subsystem']
      BackupType = $btype
      Destination = $dest
      CHECKSUM = $checksum
      COMPRESSION = $compr
      OnDataVolume_F = $onDataVol
      CommandPreview = ($(if ($cmd.Length -gt 300) { $cmd.Substring(0,300) + '...' } else { $cmd }))
    }
    if ($onDataVol) {
      $critAlerts += [pscustomobject]@{ Instance=$inst; Alert=("Job '{0}' step '{1}' writes to DATA volume path: {2}" -f $r['job_name'], $r['step_name'], $dest) }
    }
  }

  # D) Maintenance plans
  $mp = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlMaintPlans
  Write-SectionFile (Join-Path $instDir 'D_maint_plans.tsv') (Convert-DataTableToTsv $mp)
  [void]$md.AppendLine("## D) Maintenance plans")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $mp))
  [void]$md.AppendLine('```')

  $ssis = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlSsisPackages
  Write-SectionFile (Join-Path $instDir 'D_ssis_packages.tsv') (Convert-DataTableToTsv $ssis)
  [void]$md.AppendLine("## D) SSIS packages in msdb (names)")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $ssis))
  [void]$md.AppendLine('```')

  $ssisText = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlSsisPackageText -QueryTimeout 180
  # Extract path-like strings only (avoid dumping huge binary garbage)
  $pathHits = New-Object System.Text.StringBuilder
  if ($ssisText.Columns.Contains('package_text_sample')) {
    foreach ($r in $ssisText.Rows) {
      $pname = [string]$r['package_name']
      $txt = [string]$r['package_text_sample']
      if ([string]::IsNullOrEmpty($txt)) { continue }
      $matches = [regex]::Matches($txt, '(?i)[A-Za-z]:\\[^\s""<>|]{3,200}')
      $uniq = $matches | ForEach-Object { $_.Value } | Select-Object -Unique
      [void]$pathHits.AppendLine("PACKAGE: $pname")
      foreach ($u in $uniq) { [void]$pathHits.AppendLine("  PATH: $u") }
      if ($uniq | Where-Object { $_ -match '^[Ff]:\\' }) {
        $critAlerts += [pscustomobject]@{ Instance=$inst; Alert=("Maint/SSIS package '{0}' references F: data-volume path(s)" -f $pname) }
      }
    }
  } elseif ($ssisText.Columns.Contains('ERROR') -or $ssisText.Columns.Contains('note')) {
    [void]$pathHits.AppendLine((Convert-DataTableToTsv $ssisText))
  }
  Write-SectionFile (Join-Path $instDir 'D_ssis_path_hints.txt') $pathHits.ToString()
  [void]$md.AppendLine("## D) Paths extracted from SSIS package text")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine($pathHits.ToString())
  [void]$md.AppendLine('```')

  # E) Backup history
  # Multi-result: run three separate queries for reliability
  $sqlLatest = @"
SET NOCOUNT ON;
DECLARE @since datetime = DATEADD(day, -$HistoryDays, GETDATE());
SELECT
  bs.database_name,
  CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE bs.type END AS backup_type,
  MAX(bs.backup_finish_date) AS latest_finish,
  COUNT(*) AS backup_count,
  SUM(CASE WHEN bs.is_damaged = 1 THEN 1 ELSE 0 END) AS damaged_count
FROM msdb.dbo.backupset bs
WHERE bs.backup_start_date >= @since
GROUP BY bs.database_name, bs.type
ORDER BY bs.database_name, backup_type;
"@
  $sqlRoots = @"
SET NOCOUNT ON;
DECLARE @since datetime = DATEADD(day, -$HistoryDays, GETDATE());
SELECT DISTINCT
  bs.database_name,
  CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE bs.type END AS backup_type,
  bmf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= @since
ORDER BY bs.database_name, backup_type, bmf.physical_device_name;
"@
  $sqlGaps = @"
SET NOCOUNT ON;
DECLARE @since datetime = DATEADD(day, -$HistoryDays, GETDATE());
;WITH latest AS (
  SELECT database_name, type, MAX(backup_finish_date) AS latest_finish, COUNT(*) AS cnt
  FROM msdb.dbo.backupset
  WHERE backup_start_date >= @since
  GROUP BY database_name, type
)
SELECT
  d.name AS database_name,
  d.recovery_model_desc,
  d.state_desc,
  lf.latest_finish AS last_full,
  ld.latest_finish AS last_diff,
  ll.latest_finish AS last_log,
  ISNULL(lf.cnt,0) AS full_count_14d,
  ISNULL(ld.cnt,0) AS diff_count_14d,
  ISNULL(ll.cnt,0) AS log_count_14d,
  CASE WHEN d.recovery_model_desc = 'FULL' AND (ll.latest_finish IS NULL OR ll.latest_finish < DATEADD(hour,-24,GETDATE())) THEN 1 ELSE 0 END AS gap_no_log_24h,
  CASE WHEN lf.latest_finish IS NULL OR lf.latest_finish < DATEADD(day,-8,GETDATE()) THEN 1 ELSE 0 END AS gap_no_full_8d,
  CASE WHEN ISNULL(ld.cnt,0) = 0 THEN 'NO_DIFF_14D'
       WHEN ISNULL(ld.cnt,0) < 10 THEN 'DIFF_SPARSE'
       ELSE 'DIFF_OK_HINT' END AS diff_freq_hint
FROM sys.databases d
LEFT JOIN latest lf ON lf.database_name = d.name AND lf.type = 'D'
LEFT JOIN latest ld ON ld.database_name = d.name AND ld.type = 'I'
LEFT JOIN latest ll ON ll.database_name = d.name AND ll.type = 'L'
WHERE d.name NOT IN ('tempdb')
ORDER BY d.name;
"@

  $latest = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlLatest
  $roots = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlRoots
  $gaps = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlGaps
  $fails = Invoke-SqlText -Instance $inst -Database 'msdb' -Query $sqlBackupFailures

  Write-SectionFile (Join-Path $instDir 'E_backup_latest.tsv') (Convert-DataTableToTsv $latest)
  Write-SectionFile (Join-Path $instDir 'E_backup_devices.tsv') (Convert-DataTableToTsv $roots)
  Write-SectionFile (Join-Path $instDir 'E_backup_gaps.tsv') (Convert-DataTableToTsv $gaps)
  Write-SectionFile (Join-Path $instDir 'E_job_failures.tsv') (Convert-DataTableToTsv $fails)

  [void]$md.AppendLine("## E) Backup history latest (last $HistoryDays days)")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $latest))
  [void]$md.AppendLine('```')
  [void]$md.AppendLine("## E) Distinct physical devices")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $roots))
  [void]$md.AppendLine('```')
  [void]$md.AppendLine("## E) Gap analysis")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $gaps))
  [void]$md.AppendLine('```')
  [void]$md.AppendLine("## E) Related job failures")
  [void]$md.AppendLine('```')
  [void]$md.AppendLine((Convert-DataTableToTsv $fails))
  [void]$md.AppendLine('```')

  foreach ($r in $gaps.Rows) {
    if ($r.Table.Columns.Contains('ERROR')) { break }
    $allGapRows += [pscustomobject]@{
      Instance = $inst
      Database = [string]$r['database_name']
      Recovery = [string]$r['recovery_model_desc']
      LastFull = [string]$r['last_full']
      LastDiff = [string]$r['last_diff']
      LastLog = [string]$r['last_log']
      Full14 = $r['full_count_14d']
      Diff14 = $r['diff_count_14d']
      Log14 = $r['log_count_14d']
      GapNoLog24h = $r['gap_no_log_24h']
      GapNoFull8d = $r['gap_no_full_8d']
      DiffHint = [string]$r['diff_freq_hint']
    }
  }

  # F) Cleanup / xp_delete_file already partially in steps; summarize
  [void]$md.AppendLine("## F) Cleanup / retention signals")
  $cleanupSteps = @($destMatrix | Where-Object { $_.Instance -eq $inst -and ($_.BackupType -eq 'CLEANUP' -or $_.CommandPreview -match 'xp_delete_file|Delete|\.bak|\.trn') })
  if ($cleanupSteps.Count -eq 0) {
    [void]$md.AppendLine("No xp_delete_file / explicit cleanup steps detected in filtered job steps.")
  } else {
    foreach ($c in $cleanupSteps) {
      [void]$md.AppendLine("- Job=$($c.Job) Step=$($c.Step) Dest=$($c.Destination)")
      [void]$md.AppendLine("  $($c.CommandPreview)")
    }
  }

  Write-SectionFile (Join-Path $instDir 'INSTANCE_REPORT.md') $md.ToString()
  $summaryParts += $md.ToString()
}

# ---------- Build consolidated gap report ----------
$gapMd = New-Object System.Text.StringBuilder
[void]$gapMd.AppendLine("# MSSQL Backup Audit - Gap Report")
[void]$gapMd.AppendLine("")
[void]$gapMd.AppendLine("**Host:** $SqlHost  ")
[void]$gapMd.AppendLine("**Instances:** $($Instances -join ', ')  ")
[void]$gapMd.AppendLine("**Collected:** $stamp ($utcStamp) from $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME  ")
[void]$gapMd.AppendLine("**Mode:** READ-ONLY (report folder write only; no ALTER / no deletes / no job changes)")
[void]$gapMd.AppendLine("")
[void]$gapMd.AppendLine("## Target policy (desired end-state)")
[void]$gapMd.AppendLine("- Hourly transaction log backups")
[void]$gapMd.AppendLine("- Daily differential backups")
[void]$gapMd.AppendLine("- Weekly full backups")
[void]$gapMd.AppendLine("- Logs and backups on G: backup folders (log/backup volumes)")
[void]$gapMd.AppendLine("- Old backups properly pruned")
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Critical alerts")
if ($critAlerts.Count -eq 0) {
  [void]$gapMd.AppendLine("_No critical alerts auto-detected (still review disk table)._")
} else {
  foreach ($a in ($critAlerts | Select-Object -Unique Instance, Alert)) {
    [void]$gapMd.AppendLine("- **$($a.Instance):** $($a.Alert)")
  }
}
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Disk free space")
[void]$gapMd.AppendLine("See ``00_disk_volumes.md`` and per-instance ``A_volume_stats.tsv`` (authoritative for SQL-visible mounts).")
[void]$gapMd.AppendLine("")
# Build a quick table from per-instance volume stats files
[void]$gapMd.AppendLine("| Instance | Mount | Total GB | Free GB | Free % |")
[void]$gapMd.AppendLine("|----------|-------|----------|---------|--------|")
foreach ($inst in $Instances) {
  $vf = Join-Path $OutRoot "per-instance\$inst\A_volume_stats.tsv"
  if (Test-Path $vf) {
    $lines = Get-Content $vf
    if ($lines.Count -gt 1) {
      foreach ($line in $lines | Select-Object -Skip 1) {
        if ($line -match '^ERROR') { [void]$gapMd.AppendLine("| $inst | ERROR | | | |"); continue }
        $p = $line -split "`t"
        if ($p.Count -ge 6) {
          [void]$gapMd.AppendLine("| $inst | $($p[0]) | $($p[3]) | $($p[4]) | $($p[5]) |")
        }
      }
    }
  }
}
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Job / schedule matrix")
[void]$gapMd.AppendLine("| Instance | Job | Enabled | Schedule | Freq | Last outcome | Last run | Next run |")
[void]$gapMd.AppendLine("|----------|-----|---------|----------|------|--------------|----------|----------|")
foreach ($j in $jobMatrix) {
  [void]$gapMd.AppendLine("| $($j.Instance) | $($j.Job) | $($j.Enabled) | $($j.Schedule) | $($j.Freq) | $($j.LastOutcome) | $($j.LastRunDate) $($j.LastRunTime) | $($j.NextRunDate) $($j.NextRunTime) |")
}
if ($jobMatrix.Count -eq 0) { [void]$gapMd.AppendLine("| - | _No matching jobs found_ | | | | | | |") }
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Destination path matrix")
[void]$gapMd.AppendLine("| Instance | Job | Step | Type | Destination | On F: data? | CHECKSUM | COMPRESSION |")
[void]$gapMd.AppendLine("|----------|-----|------|------|-------------|-------------|----------|-------------|")
foreach ($d in $destMatrix) {
  [void]$gapMd.AppendLine("| $($d.Instance) | $($d.Job) | $($d.Step) | $($d.BackupType) | $($d.Destination) | $($d.OnDataVolume_F) | $($d.CHECKSUM) | $($d.COMPRESSION) |")
}
if ($destMatrix.Count -eq 0) { [void]$gapMd.AppendLine("| - | _No backup steps parsed_ | | | | | | |") }
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Gap vs target (per database)")
[void]$gapMd.AppendLine("| Instance | DB | Recovery | Last FULL | Last DIFF | Last LOG | #FULL14 | #DIFF14 | #LOG14 | No LOG 24h | No FULL 8d | DIFF hint |")
[void]$gapMd.AppendLine("|----------|----|----------|-----------|-----------|----------|---------|---------|--------|------------|------------|-----------|")
foreach ($g in $allGapRows) {
  [void]$gapMd.AppendLine("| $($g.Instance) | $($g.Database) | $($g.Recovery) | $($g.LastFull) | $($g.LastDiff) | $($g.LastLog) | $($g.Full14) | $($g.Diff14) | $($g.Log14) | $($g.GapNoLog24h) | $($g.GapNoFull8d) | $($g.DiffHint) |")
}
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Policy compliance summary")
function Test-HasHourlyLog {
  param($matrix)
  foreach ($j in $matrix) {
    if ($j.Freq -match 'every 1 Hours' -or $j.Freq -match 'every 60 Minutes' -or ($j.Freq -match 'Hours' -and $j.Freq -match 'every 1 ')) { return $true }
    if ($j.Job -match '(?i)log' -and $j.Freq -match 'Minutes' -and $j.Freq -match 'every (15|30|60) ') { return $true }
  }
  return $false
}
foreach ($inst in $Instances) {
  $jm = @($jobMatrix | Where-Object Instance -eq $inst)
  $dm = @($destMatrix | Where-Object Instance -eq $inst)
  $gapsI = @($allGapRows | Where-Object Instance -eq $inst)
  $hasLogJob = @($dm | Where-Object BackupType -eq 'LOG').Count -gt 0
  $hasDiffJob = @($dm | Where-Object BackupType -eq 'DIFF').Count -gt 0
  $hasFullJob = @($dm | Where-Object BackupType -eq 'FULL').Count -gt 0
  $hasCleanup = @($dm | Where-Object { $_.BackupType -eq 'CLEANUP' -or $_.CommandPreview -match 'xp_delete_file' }).Count -gt 0
  $onF = @($dm | Where-Object OnDataVolume_F -eq $true).Count
  $onG = @($dm | Where-Object { $_.Destination -match '^[GgHh]:\\' }).Count
  $fullGaps = @($gapsI | Where-Object { $_.GapNoFull8d -eq 1 -or $_.GapNoFull8d -eq '1' }).Count
  $logGaps = @($gapsI | Where-Object { ($_.Recovery -eq 'FULL') -and ($_.GapNoLog24h -eq 1 -or $_.GapNoLog24h -eq '1') }).Count

  [void]$gapMd.AppendLine("### $inst")
  [void]$gapMd.AppendLine("- FULL backup job/step present: **$hasFullJob** (target: weekly FULL)")
  [void]$gapMd.AppendLine("- DIFF backup job/step present: **$hasDiffJob** (target: daily DIFF)")
  [void]$gapMd.AppendLine("- LOG backup job/step present: **$hasLogJob** (target: hourly LOG)")
  [void]$gapMd.AppendLine("- Cleanup/xp_delete_file present: **$hasCleanup** (target: pruning)")
  [void]$gapMd.AppendLine("- Destinations on F: (data): **$onF** (target: 0)")
  [void]$gapMd.AppendLine("- Destinations on G:/H: (backup): **$onG**")
  [void]$gapMd.AppendLine("- DBs missing FULL in 8d: **$fullGaps**")
  [void]$gapMd.AppendLine("- FULL-recovery DBs missing LOG in 24h: **$logGaps**")
  [void]$gapMd.AppendLine("- Matching Agent jobs: **$($jm.Count)**")
  [void]$gapMd.AppendLine("")
}

[void]$gapMd.AppendLine("## Retention findings")
[void]$gapMd.AppendLine("See per-instance ``A_backup_folders.txt`` for oldest/newest on-disk samples, and job steps mentioning ``xp_delete_file`` in the destination matrix.")
[void]$gapMd.AppendLine("")

[void]$gapMd.AppendLine("## Recommended changes (DO NOT APPLY - plan only)")
[void]$gapMd.AppendLine("1. Confirm/remediate low free space on backup/log mounts (see volume stats) before adding more backup traffic; if critical, purge obsolete backups/logs on that volume first (after verifying restore chain).")
[void]$gapMd.AppendLine("2. For each configured instance: ensure a **weekly FULL** backup job/plan exists, enabled, CHECKSUM + COMPRESSION, destination under that instance backup folder (not the data volume).")
[void]$gapMd.AppendLine("3. For each instance: add/enable **daily DIFF** to that instance configured backup folder.")
[void]$gapMd.AppendLine("4. For each instance: add/enable **hourly LOG** backups for all FULL recovery databases to the configured backup folder; verify no FULL-recovery DB remains with log_reuse_wait_desc=LOG_BACKUP.")
[void]$gapMd.AppendLine("5. Move any jobs/plans still writing ``*.bak/*.trn`` onto data volumes onto the configured backup folders; update maintenance-plan SSIS paths accordingly.")
[void]$gapMd.AppendLine("6. Standardize **xp_delete_file** (or cleanup task) retention: e.g. FULL keep N weeks, DIFF keep N days, LOG keep N hours/days - aligned with backup frequency; schedule cleanup after successful backups.")
[void]$gapMd.AppendLine("7. Set instance ``BackupDirectory`` registry default to the configured backup root for each instance so ad-hoc backups land correctly.")
[void]$gapMd.AppendLine("8. Re-run this audit script after changes; confirm gap columns No LOG 24h / No FULL 8d are zero for user DBs and disk free space recovers on backup mounts.")
[void]$gapMd.AppendLine("")
[void]$gapMd.AppendLine("## Evidence index")
[void]$gapMd.AppendLine("- ``00_disk_volumes.md``")
[void]$gapMd.AppendLine("- ``per-instance\<instance>\*.tsv|*.txt|INSTANCE_REPORT.md``")
[void]$gapMd.AppendLine("- ``GAP_REPORT.md`` (this file)")
[void]$gapMd.AppendLine("- ``SUMMARY.md`` (short)")

Write-SectionFile (Join-Path $OutRoot 'GAP_REPORT.md') $gapMd.ToString()

# Short summary
$sum = New-Object System.Text.StringBuilder
[void]$sum.AppendLine("# Backup audit summary")
[void]$sum.AppendLine("")
[void]$sum.AppendLine("Collected $stamp from $env:COMPUTERNAME against $SqlHost \{$(($Instances -join ','))}. READ-ONLY.")
[void]$sum.AppendLine("")
[void]$sum.AppendLine("## Critical alerts")
if ($critAlerts.Count -eq 0) { [void]$sum.AppendLine("- (none auto-flagged)") }
else { foreach ($a in $critAlerts | Select-Object -Unique Instance,Alert) { [void]$sum.AppendLine("- $($a.Instance): $($a.Alert)") } }
[void]$sum.AppendLine("")
[void]$sum.AppendLine("## Jobs found: $($jobMatrix.Count)  |  Backup steps parsed: $($destMatrix.Count)  |  DB gap rows: $($allGapRows.Count)")
[void]$sum.AppendLine("")
[void]$sum.AppendLine("Full gap report: GAP_REPORT.md")
[void]$sum.AppendLine("Per-instance detail: per-instance\")
Write-SectionFile (Join-Path $OutRoot 'SUMMARY.md') $sum.ToString()

# Machine-readable dumps
$jobMatrix | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutRoot 'raw\job_matrix.json') -Encoding UTF8
$destMatrix | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutRoot 'raw\dest_matrix.json') -Encoding UTF8
$allGapRows | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutRoot 'raw\gap_rows.json') -Encoding UTF8
$critAlerts | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutRoot 'raw\crit_alerts.json') -Encoding UTF8

Write-Host "DONE. Reports at $OutRoot" -ForegroundColor Green
Write-Output "REPORT_ROOT=$OutRoot"
Write-Output "SUMMARY=$OutRoot\SUMMARY.md"
Write-Output "GAP=$OutRoot\GAP_REPORT.md"
