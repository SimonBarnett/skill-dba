#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlHost,
    [Parameter(Mandatory = $true)]
    [string[]]$Instances,
    [Parameter(Mandatory = $true)]
    [string]$OutRoot
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null

function Invoke-Sql {
  param([string]$Instance, [string]$Query, [string]$Database = 'master')
  $cs = "Server=$SqlHost\$Instance;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=30;"
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $Query
  $cmd.CommandTimeout = 180
  $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
  $dt = New-Object System.Data.DataTable
  try {
    $conn.Open()
    [void]$da.Fill($dt)
  } catch {
    Write-Host ("SQL ERR {0}: {1}" -f $Instance, $_.Exception.Message)
  } finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
  }
  return $dt
}

function Save-Tsv {
  param($Table, [string]$Path)
  if (-not $Table -or $Table.Columns.Count -eq 0) {
    Set-Content -Path $Path -Value '(empty)' -Encoding UTF8
    return
  }
  $cols = @($Table.Columns | ForEach-Object { $_.ColumnName })
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add(($cols -join "`t"))
  foreach ($row in $Table.Rows) {
    $vals = foreach ($c in $cols) {
      (([string]$row[$c]) -replace "[\t\r\n]", ' ')
    }
    [void]$lines.Add(($vals -join "`t"))
  }
  Set-Content -Path $Path -Value $lines -Encoding UTF8
}

$report = New-Object System.Collections.Generic.List[string]
[void]$report.Add('# MSSQL backup audit (live)')
[void]$report.Add(('Collected ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' from ' + $env:COMPUTERNAME + ' against ' + $SqlHost + ' - READ-ONLY'))
[void]$report.Add('')
[void]$report.Add('## Disk snapshot')
[void]$report.Add('Collect mount-point free space from host WMI or SQL dm_os_volume_stats per deployment docs; not embedded in this script.')
[void]$report.Add('')

foreach ($inst in @($Instances)) {
  Write-Host ("=== {0} ===" -f $inst)
  $idir = Join-Path $OutRoot $inst
  New-Item -ItemType Directory -Force -Path $idir | Out-Null
  [void]$report.Add(("## Instance {0}" -f $inst))
  [void]$report.Add('')

  $q1 = @'
DECLARE @v NVARCHAR(512);
EXEC master.dbo.xp_instance_regread
  N'HKEY_LOCAL_MACHINE',
  N'Software\Microsoft\MSSQLServer\MSSQLServer',
  N'BackupDirectory',
  @v OUTPUT;
SELECT @@SERVERNAME AS server_name,
       ISNULL(@v,'(null)') AS BackupDirectory,
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version;
'@
  $bd = Invoke-Sql $inst $q1
  Save-Tsv $bd (Join-Path $idir '00_backupdir.tsv')
  if ($bd.Rows.Count -gt 0) {
    [void]$report.Add(('- Server: ' + [string]$bd.Rows[0]['server_name'] + ' | ' + [string]$bd.Rows[0]['edition'] + ' | BackupDirectory: ' + [string]$bd.Rows[0]['BackupDirectory']))
  } else {
    [void]$report.Add('- BackupDirectory query returned no rows')
  }

  $q2 = @'
SELECT d.name,
       d.recovery_model_desc,
       d.state_desc,
       d.log_reuse_wait_desc,
       CAST(SUM(CASE WHEN mf.type_desc='ROWS' THEN mf.size ELSE 0 END)*8.0/1024/1024 AS decimal(12,2)) AS data_gb,
       CAST(SUM(CASE WHEN mf.type_desc='LOG' THEN mf.size ELSE 0 END)*8.0/1024/1024 AS decimal(12,2)) AS log_gb
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id > 4
GROUP BY d.name, d.recovery_model_desc, d.state_desc, d.log_reuse_wait_desc
ORDER BY d.name;
'@
  $dbs = Invoke-Sql $inst $q2
  Save-Tsv $dbs (Join-Path $idir '01_databases.tsv')
  $fullCount = @($dbs.Rows | Where-Object { $_['recovery_model_desc'] -eq 'FULL' }).Count
  $logWait = @($dbs.Rows | Where-Object { $_['log_reuse_wait_desc'] -eq 'LOG_BACKUP' }).Count
  [void]$report.Add(("- User DBs: {0}; FULL recovery: {1}; waiting on LOG_BACKUP: {2}" -f $dbs.Rows.Count, $fullCount, $logWait))

  $q3 = @'
SELECT DB_NAME(database_id) AS db_name, type_desc, name AS logical_name, physical_name,
       CAST(size*8.0/1024/1024 AS decimal(12,2)) AS size_gb
FROM sys.master_files
WHERE database_id > 4
ORDER BY database_id, type, file_id;
'@
  Save-Tsv (Invoke-Sql $inst $q3) (Join-Path $idir '02_master_files.tsv')

  $q4 = @'
SELECT j.name AS job_name,
       j.enabled,
       ISNULL(c.name,'') AS category,
       CASE jh.run_status
         WHEN 0 THEN 'Failed'
         WHEN 1 THEN 'Succeeded'
         WHEN 2 THEN 'Retry'
         WHEN 3 THEN 'Canceled'
         WHEN 4 THEN 'InProgress'
         ELSE ISNULL(CAST(jh.run_status AS varchar(8)),'')
       END AS last_status,
       jh.run_date,
       jh.run_time,
       (
         SELECT TOP 1
           'freq_type=' + CAST(s.freq_type AS varchar(8))
           + ' interval=' + CAST(s.freq_interval AS varchar(8))
           + ' subday_type=' + CAST(s.freq_subday_type AS varchar(8))
           + ' subday_interval=' + CAST(s.freq_subday_interval AS varchar(8))
           + ' start=' + CAST(s.active_start_time AS varchar(8))
         FROM msdb.dbo.sysjobschedules js2
         JOIN msdb.dbo.sysschedules s ON s.schedule_id = js2.schedule_id
         WHERE js2.job_id = j.job_id
         ORDER BY s.schedule_id
       ) AS schedule_hint
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
OUTER APPLY (
  SELECT TOP 1 run_date, run_time, run_status
  FROM msdb.dbo.sysjobhistory h
  WHERE h.job_id = j.job_id AND h.step_id = 0
  ORDER BY h.instance_id DESC
) jh
WHERE j.name LIKE '%backup%' OR j.name LIKE '%Backup%'
   OR j.name LIKE '%maint%' OR j.name LIKE '%Maint%' OR j.name LIKE '%Maintenance%'
   OR ISNULL(c.name,'') LIKE '%Backup%'
   OR ISNULL(c.name,'') LIKE '%Database Maintenance%'
ORDER BY j.name;
'@
  $jobs = Invoke-Sql $inst $q4
  Save-Tsv $jobs (Join-Path $idir '03_jobs.tsv')
  [void]$report.Add(("- Matching Agent jobs: {0}" -f $jobs.Rows.Count))
  foreach ($r in @($jobs.Rows)) {
    [void]$report.Add(("  - {0} | enabled={1} | last={2} {3} {4} | {5}" -f $r['job_name'], $r['enabled'], $r['last_status'], $r['run_date'], $r['run_time'], $r['schedule_hint']))
  }

  $q5 = @'
SELECT j.name AS job_name, js.step_id, js.step_name, js.subsystem,
       LEFT(REPLACE(REPLACE(js.command, CHAR(9), ' '), CHAR(13), ' '), 1800) AS command_preview
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE j.name LIKE '%backup%' OR j.name LIKE '%Backup%'
   OR j.name LIKE '%maint%' OR j.name LIKE '%Maint%' OR j.name LIKE '%Maintenance%'
   OR js.command LIKE '%BACKUP %' OR js.command LIKE '%xp_delete_file%'
ORDER BY j.name, js.step_id;
'@
  $steps = Invoke-Sql $inst $q5
  Save-Tsv $steps (Join-Path $idir '04_job_steps.tsv')
  [void]$report.Add(("- Job steps captured: {0}" -f $steps.Rows.Count))

  try {
    $plans = Invoke-Sql $inst 'SELECT name, CONVERT(varchar(40), id) AS plan_id FROM msdb.dbo.sysmaintplan_plans ORDER BY name;'
    Save-Tsv $plans (Join-Path $idir '05_maint_plans.tsv')
    [void]$report.Add(("- Maintenance plans: {0}" -f $plans.Rows.Count))
    foreach ($r in @($plans.Rows)) { [void]$report.Add(("  - {0}" -f $r['name'])) }

    $q6 = @'
SELECT p.name AS plan_name, sp.subplan_name, j.name AS job_name, j.enabled
FROM msdb.dbo.sysmaintplan_plans p
JOIN msdb.dbo.sysmaintplan_subplans sp ON sp.plan_id = p.id
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = sp.job_id
ORDER BY p.name, sp.subplan_name;
'@
    Save-Tsv (Invoke-Sql $inst $q6) (Join-Path $idir '06_maint_subplans.tsv')
  } catch {
    [void]$report.Add(("- Maintenance plans: ERROR {0}" -f $_.Exception.Message))
  }

  $q7 = @'
SELECT database_name,
       MAX(CASE WHEN type='D' THEN backup_finish_date END) AS last_full,
       MAX(CASE WHEN type='I' THEN backup_finish_date END) AS last_diff,
       MAX(CASE WHEN type='L' THEN backup_finish_date END) AS last_log,
       SUM(CASE WHEN type='D' AND backup_finish_date >= DATEADD(day,-14,GETDATE()) THEN 1 ELSE 0 END) AS full_14d,
       SUM(CASE WHEN type='I' AND backup_finish_date >= DATEADD(day,-14,GETDATE()) THEN 1 ELSE 0 END) AS diff_14d,
       SUM(CASE WHEN type='L' AND backup_finish_date >= DATEADD(day,-14,GETDATE()) THEN 1 ELSE 0 END) AS log_14d
FROM msdb.dbo.backupset
WHERE database_name NOT IN ('tempdb')
  AND backup_finish_date >= DATEADD(day,-35,GETDATE())
GROUP BY database_name
ORDER BY database_name;
'@
  $hist = Invoke-Sql $inst $q7
  Save-Tsv $hist (Join-Path $idir '07_backup_history.tsv')
  [void]$report.Add('- Recent backup ages:')
  foreach ($r in @($hist.Rows)) {
    [void]$report.Add(("  - {0}: FULL={1} x{2} | DIFF={3} x{4} | LOG={5} x{6}" -f $r['database_name'], $r['last_full'], $r['full_14d'], $r['last_diff'], $r['diff_14d'], $r['last_log'], $r['log_14d']))
  }

  $q8 = @'
SELECT TOP 50 bmf.physical_device_name, bs.type, COUNT(*) AS cnt, MAX(bs.backup_finish_date) AS last_backup
FROM msdb.dbo.backupmediafamily bmf
JOIN msdb.dbo.backupset bs ON bs.media_set_id = bmf.media_set_id
WHERE bs.backup_finish_date >= DATEADD(day,-14,GETDATE())
GROUP BY bmf.physical_device_name, bs.type
ORDER BY last_backup DESC;
'@
  Save-Tsv (Invoke-Sql $inst $q8) (Join-Path $idir '08_backup_devices.tsv')

  $q9 = @'
SELECT j.name AS job_name, js.step_id, js.step_name,
       LEFT(REPLACE(REPLACE(js.command, CHAR(9), ' '), CHAR(13), ' '), 1500) AS command_preview
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
WHERE js.command LIKE '%xp_delete_file%'
   OR js.command LIKE '%Cleanup%'
   OR js.command LIKE '%Maintenance Cleanup%'
ORDER BY j.name, js.step_id;
'@
  $clean = Invoke-Sql $inst $q9
  Save-Tsv $clean (Join-Path $idir '09_cleanup_steps.tsv')
  [void]$report.Add(("- Cleanup-related steps: {0}" -f $clean.Rows.Count))
  [void]$report.Add('')
}

[void]$report.Add('## Target vs current (gap - no changes made)')
[void]$report.Add('Desired: hourly t-log, daily differential, weekly full; backups on G: backup folders; old files pruned.')
[void]$report.Add('See job/history sections above for compliance.')

$gapPath = Join-Path $OutRoot 'GAP_LIVE.md'
Set-Content -Path $gapPath -Value $report -Encoding UTF8
Write-Host ("WROTE {0}" -f $gapPath)
Get-Content $gapPath
