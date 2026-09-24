/*==============================================================================
  dba_instance_health_collect.sql
  Portable early-warning collection for Microsoft SQL Server instances.
  Target host and instance come from config (do not hard-code a customer).

  Run from a jump host with Windows Integrated auth, e.g.:
    sqlcmd -S HOST\INSTANCE -E -C -i dba_instance_health_collect.sql -o report.txt

  Requires: VIEW SERVER STATE (and ability to read msdb backup/job history).
  Designed to surface disk, memory, and other signals before they become outages.
==============================================================================*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE
    @WarnFreePct       decimal(5,2) = 20.00,
    @CritFreePct       decimal(5,2) = 10.00,
    @WarnFreeGB        decimal(18,2) = 50.00,
    @CritFreeGB        decimal(18,2) = 20.00,
    @WarnFileUsedPct   decimal(5,2) = 80.00,
    @CritFileUsedPct   decimal(5,2) = 90.00,
    @WarnTempdbUsedPct decimal(5,2) = 70.00,
    @WarnLogUsedPct    decimal(5,2) = 70.00,
    @CritLogUsedPct    decimal(5,2) = 90.00,
    @WarnPLE           bigint = 300,          -- seconds; tune per workload / NUMA
    @WarnRunnable      int = 5,
    @WarnIoLatencyMs   bigint = 50,
    @CollectUtc        datetime2(0) = SYSUTCDATETIME();

DECLARE @ServerName sysname = CAST(@@SERVERNAME AS sysname);

/*------------------------------------------------------------------------------
  1) Instance header
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS instance_name,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
    CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
    sqlserver_start_time,
    DATEDIFF(hour, sqlserver_start_time, SYSDATETIME()) AS uptime_hours,
    cpu_count,
    hyperthread_ratio,
    physical_memory_kb / 1024 AS physical_memory_mb,
    committed_kb / 1024 AS committed_mb,
    committed_target_kb / 1024 AS committed_target_mb
FROM sys.dm_os_sys_info;

/*------------------------------------------------------------------------------
  2) Volume capacity (primary disk early-warning)
------------------------------------------------------------------------------*/
;WITH vols AS (
    SELECT DISTINCT
        vs.volume_mount_point,
        vs.logical_volume_name,
        vs.file_system_type,
        vs.total_bytes,
        vs.available_bytes
    FROM sys.master_files AS mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
)
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    volume_mount_point,
    logical_volume_name,
    file_system_type,
    CAST(total_bytes / 1024.0 / 1024 / 1024 AS decimal(18,2)) AS total_gb,
    CAST(available_bytes / 1024.0 / 1024 / 1024 AS decimal(18,2)) AS free_gb,
    CAST((total_bytes - available_bytes) / 1024.0 / 1024 / 1024 AS decimal(18,2)) AS used_gb,
    CAST(100.0 * available_bytes / NULLIF(total_bytes, 0) AS decimal(5,2)) AS free_pct,
    CASE
        WHEN 100.0 * available_bytes / NULLIF(total_bytes, 0) < @CritFreePct
          OR available_bytes / 1024.0 / 1024 / 1024 < @CritFreeGB THEN 'CRITICAL'
        WHEN 100.0 * available_bytes / NULLIF(total_bytes, 0) < @WarnFreePct
          OR available_bytes / 1024.0 / 1024 / 1024 < @WarnFreeGB THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM vols
ORDER BY free_pct ASC, free_gb ASC;

/* Fallback drive free space (MB) - useful if volume_stats is limited */
EXEC sys.xp_fixeddrives;

/*------------------------------------------------------------------------------
  3) Database file inventory + growth headroom
------------------------------------------------------------------------------*/
;WITH files AS (
    SELECT
        DB_NAME(mf.database_id) AS database_name,
        mf.database_id,
        mf.file_id,
        mf.type_desc,
        mf.name AS logical_name,
        mf.physical_name,
        mf.size * 8.0 / 1024 AS size_mb,
        mf.max_size,
        CASE
            WHEN mf.max_size = -1 THEN NULL
            WHEN mf.max_size = 268435456 THEN NULL  -- unlimited log sentinel sometimes
            ELSE mf.max_size * 8.0 / 1024
        END AS max_size_mb,
        mf.growth,
        mf.is_percent_growth,
        vs.volume_mount_point,
        vs.available_bytes / 1024.0 / 1024 AS volume_free_mb,
        FILEPROPERTY(mf.name, 'SpaceUsed') AS space_used_pages  -- NULL outside DB context for other DBs
    FROM sys.master_files AS mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
)
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    database_name,
    type_desc,
    logical_name,
    physical_name,
    volume_mount_point,
    CAST(size_mb AS decimal(18,2)) AS size_mb,
    CAST(max_size_mb AS decimal(18,2)) AS max_size_mb,
    CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(20)) + '%'
         ELSE CAST(growth * 8 / 1024 AS varchar(20)) + ' MB' END AS growth_setting,
    CAST(volume_free_mb AS decimal(18,2)) AS volume_free_mb,
    CASE
        WHEN growth = 0 THEN 'NO_GROWTH'
        WHEN max_size_mb IS NOT NULL AND size_mb >= max_size_mb * 0.95 THEN 'NEAR_MAX_SIZE'
        WHEN is_percent_growth = 0 AND (growth * 8.0 / 1024) > volume_free_mb THEN 'NEXT_GROWTH_WONT_FIT'
        WHEN is_percent_growth = 1 AND (size_mb * growth / 100.0) > volume_free_mb THEN 'NEXT_GROWTH_WONT_FIT'
        ELSE 'OK'
    END AS growth_risk
FROM files
ORDER BY database_name, type_desc, file_id;

/* Per-DB used space (accurate SpaceUsed) */
DECLARE @db sysname;
DECLARE @sql nvarchar(max);
IF OBJECT_ID('tempdb..#file_used') IS NOT NULL DROP TABLE #file_used;
CREATE TABLE #file_used (
    database_name sysname,
    file_id int,
    type_desc nvarchar(60),
    logical_name sysname,
    size_mb decimal(18,2),
    used_mb decimal(18,2),
    free_mb decimal(18,2),
    used_pct decimal(5,2)
);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE' AND HAS_DBACCESS(name) = 1;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    USE ' + QUOTENAME(@db) + N';
    INSERT INTO #file_used (database_name, file_id, type_desc, logical_name, size_mb, used_mb, free_mb, used_pct)
    SELECT
        DB_NAME(),
        file_id,
        type_desc,
        name,
        CAST(size * 8.0 / 1024 AS decimal(18,2)),
        CAST(FILEPROPERTY(name, ''SpaceUsed'') * 8.0 / 1024 AS decimal(18,2)),
        CAST((size - FILEPROPERTY(name, ''SpaceUsed'')) * 8.0 / 1024 AS decimal(18,2)),
        CAST(100.0 * FILEPROPERTY(name, ''SpaceUsed'') / NULLIF(size, 0) AS decimal(5,2))
    FROM sys.database_files;';
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        /* skip DBs we cannot enter */
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @db;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    database_name,
    type_desc,
    logical_name,
    size_mb,
    used_mb,
    free_mb,
    used_pct,
    CASE
        WHEN used_pct >= @CritFileUsedPct THEN 'CRITICAL'
        WHEN used_pct >= @WarnFileUsedPct THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM #file_used
ORDER BY used_pct DESC, database_name;

/*------------------------------------------------------------------------------
  4) Tempdb pressure
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    'tempdb' AS database_name,
    SUM(total_page_count) * 8 / 1024 AS total_mb,
    SUM(allocated_extent_page_count) * 8 / 1024 AS allocated_mb,
    SUM(unallocated_extent_page_count) * 8 / 1024 AS unallocated_mb,
    SUM(version_store_reserved_page_count) * 8 / 1024 AS version_store_mb,
    SUM(user_object_reserved_page_count) * 8 / 1024 AS user_object_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_object_mb,
    SUM(mixed_extent_page_count) * 8 / 1024 AS mixed_mb,
    CAST(100.0 * SUM(allocated_extent_page_count) / NULLIF(SUM(total_page_count), 0) AS decimal(5,2)) AS allocated_pct,
    CASE
        WHEN 100.0 * SUM(allocated_extent_page_count) / NULLIF(SUM(total_page_count), 0) >= @WarnTempdbUsedPct
            THEN 'WARN' ELSE 'OK' END AS severity
FROM tempdb.sys.dm_db_file_space_usage;

SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    mf.name AS logical_name,
    mf.physical_name,
    CAST(mf.size * 8.0 / 1024 AS decimal(18,2)) AS size_mb,
    vs.volume_mount_point,
    CAST(vs.available_bytes / 1024.0 / 1024 / 1024 AS decimal(18,2)) AS volume_free_gb
FROM tempdb.sys.database_files AS mf
CROSS APPLY sys.dm_os_volume_stats(2, mf.file_id) AS vs;

/*------------------------------------------------------------------------------
  5) Log space + recovery model + last log backup age
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#logspace') IS NOT NULL DROP TABLE #logspace;
CREATE TABLE #logspace (
    database_name sysname,
    log_size_mb float,
    log_used_pct float,
    status int
);
INSERT INTO #logspace EXEC('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');

SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    ls.database_name,
    d.recovery_model_desc,
    CAST(ls.log_size_mb AS decimal(18,2)) AS log_size_mb,
    CAST(ls.log_used_pct AS decimal(5,2)) AS log_used_pct,
    lb.last_log_backup_utc,
    CASE WHEN lb.last_log_backup_utc IS NULL THEN NULL
         ELSE DATEDIFF(hour, lb.last_log_backup_utc, @CollectUtc) END AS hours_since_log_backup,
    CASE
        WHEN ls.log_used_pct >= @CritLogUsedPct THEN 'CRITICAL'
        WHEN ls.log_used_pct >= @WarnLogUsedPct THEN 'WARN'
        WHEN d.recovery_model_desc = 'FULL'
             AND (lb.last_log_backup_utc IS NULL
                  OR DATEDIFF(hour, lb.last_log_backup_utc, @CollectUtc) > 24)
             AND d.database_id > 4 THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM #logspace AS ls
JOIN sys.databases AS d ON d.name = ls.database_name
OUTER APPLY (
    SELECT MAX(backup_finish_date) AS last_log_backup_utc
    FROM msdb.dbo.backupset
    WHERE database_name = ls.database_name AND type = 'L'
) AS lb
ORDER BY ls.log_used_pct DESC;

/*------------------------------------------------------------------------------
  6) Backup destination paths (recent) + default backup directory
------------------------------------------------------------------------------*/
DECLARE @BackupDirectory nvarchar(512) = NULL;
BEGIN TRY
    EXEC master.dbo.xp_instance_regread
        N'HKEY_LOCAL_MACHINE',
        N'Software\Microsoft\MSSQLServer\MSSQLServer',
        N'BackupDirectory',
        @BackupDirectory OUTPUT;
END TRY
BEGIN CATCH
    SET @BackupDirectory = NULL;
END CATCH;

SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    @BackupDirectory AS default_backup_directory;

SELECT TOP 30
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    bs.database_name,
    bs.type AS backup_type,
    bs.backup_start_date,
    bs.backup_finish_date,
    CAST(bs.backup_size / 1024.0 / 1024 AS decimal(18,2)) AS backup_size_mb,
    bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf ON bs.media_set_id = bmf.media_set_id
ORDER BY bs.backup_finish_date DESC;

/*------------------------------------------------------------------------------
  7) Memory pressure
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    total_physical_memory_kb / 1024 AS total_physical_mb,
    available_physical_memory_kb / 1024 AS available_physical_mb,
    CAST(100.0 * available_physical_memory_kb / NULLIF(total_physical_memory_kb, 0) AS decimal(5,2)) AS available_physical_pct,
    system_memory_state_desc,
    CASE
        WHEN system_memory_state_desc <> 'Available physical memory is high' THEN 'WARN'
        WHEN 100.0 * available_physical_memory_kb / NULLIF(total_physical_memory_kb, 0) < 5 THEN 'CRITICAL'
        WHEN 100.0 * available_physical_memory_kb / NULLIF(total_physical_memory_kb, 0) < 10 THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM sys.dm_os_sys_memory;

SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    physical_memory_in_use_kb / 1024 AS sql_physical_memory_in_use_mb,
    large_page_allocations_kb / 1024 AS large_page_mb,
    locked_page_allocations_kb / 1024 AS locked_page_mb,
    total_virtual_address_space_kb / 1024 AS total_vas_mb,
    virtual_address_space_committed_kb / 1024 AS vas_committed_mb,
    virtual_address_space_available_kb / 1024 AS vas_available_mb,
    page_fault_count,
    memory_utilization_percentage,
    process_physical_memory_low,
    process_virtual_memory_low,
    CASE
        WHEN process_physical_memory_low = 1 OR process_virtual_memory_low = 1 THEN 'CRITICAL'
        WHEN memory_utilization_percentage >= 95 THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM sys.dm_os_process_memory;

/* Buffer pool / target */
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Target Server Memory (KB)' AND object_name LIKE '%Memory Manager%') / 1024 AS target_server_memory_mb,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Total Server Memory (KB)' AND object_name LIKE '%Memory Manager%') / 1024 AS total_server_memory_mb,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') AS page_life_expectancy,
    CASE
        WHEN (SELECT cntr_value FROM sys.dm_os_performance_counters
              WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') < @WarnPLE
            THEN 'WARN' ELSE 'OK' END AS ple_severity;

/* Top memory clerks */
SELECT TOP 15
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    type AS clerk_type,
    name AS clerk_name,
    memory_node_id,
    pages_kb / 1024 AS pages_mb,
    virtual_memory_reserved_kb / 1024 AS vm_reserved_mb,
    virtual_memory_committed_kb / 1024 AS vm_committed_mb,
    awe_allocated_kb / 1024 AS awe_mb
FROM sys.dm_os_memory_clerks
ORDER BY pages_kb DESC;

/* Memory-related waits (cumulative since startup - use deltas between runs) */
SELECT TOP 20
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN (
    'RESOURCE_SEMAPHORE', 'RESOURCE_SEMAPHORE_QUERY_COMPILE',
    'CMEMTHREAD', 'MEMORY_ALLOCATION_EXT', 'PAGEIOLATCH_SH', 'PAGEIOLATCH_EX',
    'WRITELOG', 'LOGBUFFER', 'XE_LIVE_TARGET_TVF'
)
ORDER BY wait_time_ms DESC;

/*------------------------------------------------------------------------------
  8) CPU / scheduler pressure
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    scheduler_id,
    cpu_id,
    is_online,
    current_tasks_count,
    runnable_tasks_count,
    current_workers_count,
    active_workers_count,
    work_queue_count,
    load_factor,
    CASE WHEN runnable_tasks_count >= @WarnRunnable THEN 'WARN' ELSE 'OK' END AS severity
FROM sys.dm_os_schedulers
WHERE scheduler_id < 255
ORDER BY runnable_tasks_count DESC, scheduler_id;

/*------------------------------------------------------------------------------
  9) Top waits (cumulative - compare runs for deltas)
------------------------------------------------------------------------------*/
SELECT TOP 25
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    wait_time_ms / 1000.0 / 60 AS wait_time_min,
    max_wait_time_ms,
    signal_wait_time_ms,
    CASE WHEN waiting_tasks_count = 0 THEN 0
         ELSE wait_time_ms / waiting_tasks_count END AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK','SLEEP_SYSTEMTASK','WAITFOR','LAZYWRITER_SLEEP','BROKER_TASK_STOP',
    'CLR_AUTO_EVENT','CLR_MANUAL_EVENT','BROKER_TO_FLUSH','BROKER_EVENTHANDLER',
    'XE_DISPATCHER_WAIT','XE_TIMER_EVENT','SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH','DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE','WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAIT_XTP_HOST_WAIT',
    'LOGMGR_QUEUE','FT_IFTS_SCHEDULER_IDLE_WAIT'
)
  AND wait_type NOT LIKE 'PREEMPTIVE_%'
  AND wait_type NOT LIKE 'SLEEP_%'
ORDER BY wait_time_ms DESC;

/*------------------------------------------------------------------------------
  10) IO latency by file
------------------------------------------------------------------------------*/
SELECT TOP 40
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    DB_NAME(vfs.database_id) AS database_name,
    mf.type_desc,
    mf.physical_name,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CASE WHEN vfs.num_of_reads = 0 THEN 0
         ELSE vfs.io_stall_read_ms / vfs.num_of_reads END AS avg_read_latency_ms,
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE vfs.io_stall_write_ms / vfs.num_of_writes END AS avg_write_latency_ms,
    CASE
        WHEN (CASE WHEN vfs.num_of_reads = 0 THEN 0 ELSE vfs.io_stall_read_ms / vfs.num_of_reads END) >= @WarnIoLatencyMs
          OR (CASE WHEN vfs.num_of_writes = 0 THEN 0 ELSE vfs.io_stall_write_ms / vfs.num_of_writes END) >= @WarnIoLatencyMs
            THEN 'WARN' ELSE 'OK' END AS severity
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
  ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY
    (CASE WHEN vfs.num_of_reads = 0 THEN 0 ELSE vfs.io_stall_read_ms / vfs.num_of_reads END)
  + (CASE WHEN vfs.num_of_writes = 0 THEN 0 ELSE vfs.io_stall_write_ms / vfs.num_of_writes END) DESC;

/*------------------------------------------------------------------------------
  11) Blocking / head blockers (point-in-time)
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    r.status,
    r.command,
    DB_NAME(r.database_id) AS database_name,
    r.cpu_time,
    r.total_elapsed_time,
    r.open_transaction_count,
    t.text AS sql_text
FROM sys.dm_exec_requests AS r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0
   OR r.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
ORDER BY r.blocking_session_id, r.session_id;

/*------------------------------------------------------------------------------
  12) Long-running transactions
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    at.transaction_id,
    at.name AS transaction_name,
    at.transaction_begin_time,
    DATEDIFF(minute, at.transaction_begin_time, SYSDATETIME()) AS duration_min,
    at.transaction_type,
    at.transaction_state,
    s.session_id,
    s.login_name,
    s.host_name,
    DB_NAME(dt.database_id) AS database_name
FROM sys.dm_tran_active_transactions AS at
JOIN sys.dm_tran_session_transactions AS st ON at.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions AS s ON st.session_id = s.session_id
LEFT JOIN sys.dm_tran_database_transactions AS dt ON at.transaction_id = dt.transaction_id
WHERE DATEDIFF(minute, at.transaction_begin_time, SYSDATETIME()) >= 15
ORDER BY at.transaction_begin_time;

/*------------------------------------------------------------------------------
  13) Database state / suspect pages / AG-ish basics
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    name AS database_name,
    state_desc,
    user_access_desc,
    recovery_model_desc,
    log_reuse_wait_desc,
    is_read_only,
    is_auto_close_on,
    is_auto_shrink_on,
    CASE WHEN state_desc <> 'ONLINE' THEN 'CRITICAL'
         WHEN is_auto_shrink_on = 1 THEN 'WARN'
         ELSE 'OK' END AS severity
FROM sys.databases
ORDER BY CASE WHEN state_desc = 'ONLINE' THEN 1 ELSE 0 END, name;

SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    DB_NAME(database_id) AS database_name,
    file_id,
    page_id,
    event_type,
    error_count,
    last_update_date
FROM msdb.dbo.suspect_pages
WHERE event_type IN (1, 2, 3)  -- 1 CRC, 2 bad checksum, 3 torn page
ORDER BY last_update_date DESC;

/*------------------------------------------------------------------------------
  14) Recent failed SQL Agent jobs
------------------------------------------------------------------------------*/
SELECT TOP 30
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    j.name AS job_name,
    h.step_name,
    h.run_date,
    h.run_time,
    h.run_duration,
    h.message
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs AS j ON h.job_id = j.job_id
WHERE h.run_status = 0  -- failed
  AND h.step_id > 0
ORDER BY h.run_date DESC, h.run_time DESC;

/*------------------------------------------------------------------------------
  15) Session / connection pressure
------------------------------------------------------------------------------*/
SELECT
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    COUNT(*) AS session_count,
    SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running_count,
    SUM(CASE WHEN status = 'sleeping' THEN 1 ELSE 0 END) AS sleeping_count,
    SUM(CASE WHEN is_user_process = 1 THEN 1 ELSE 0 END) AS user_sessions,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'user connections') AS user_connections_config
FROM sys.dm_exec_sessions;

SELECT TOP 20
    @CollectUtc AS collect_utc,
    @ServerName AS server_name,
    login_name,
    host_name,
    program_name,
    COUNT(*) AS session_count
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY login_name, host_name, program_name
ORDER BY COUNT(*) DESC;

/*------------------------------------------------------------------------------
  16) Compact alert rollup (disk + memory + state)
------------------------------------------------------------------------------*/
;WITH vol_alerts AS (
    SELECT DISTINCT
        vs.volume_mount_point AS object_name,
        CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) AS decimal(5,2)) AS free_pct,
        CAST(vs.available_bytes / 1024.0 / 1024 / 1024 AS decimal(18,2)) AS free_gb,
        CASE
            WHEN 100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) < @CritFreePct
              OR vs.available_bytes / 1024.0 / 1024 / 1024 < @CritFreeGB THEN 'CRITICAL'
            WHEN 100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) < @WarnFreePct
              OR vs.available_bytes / 1024.0 / 1024 / 1024 < @WarnFreeGB THEN 'WARN'
        END AS severity,
        'Disk free ' + CAST(CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) AS decimal(5,2)) AS varchar(20))
            + '% (' + CAST(CAST(vs.available_bytes / 1024.0 / 1024 / 1024 AS decimal(18,2)) AS varchar(20)) + ' GB)' AS detail
    FROM sys.master_files AS mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
),
mem AS (
    SELECT system_memory_state_desc, process_physical_memory_low, process_virtual_memory_low,
           memory_utilization_percentage,
           (SELECT cntr_value FROM sys.dm_os_performance_counters
            WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') AS ple
    FROM sys.dm_os_sys_memory
    CROSS JOIN sys.dm_os_process_memory
)
SELECT collect_utc, server_name, severity, category, object_name, finding
FROM (
SELECT @CollectUtc AS collect_utc, @ServerName AS server_name,
       severity, 'DISK' AS category, object_name, detail COLLATE DATABASE_DEFAULT AS finding,
       CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END AS sort_key
FROM vol_alerts
WHERE severity IS NOT NULL
UNION ALL
SELECT @CollectUtc, @ServerName, 'CRITICAL', 'MEMORY', 'process_memory',
       CAST('SQL process reports physical and/or virtual memory low' AS nvarchar(4000)) COLLATE DATABASE_DEFAULT, 1
FROM mem WHERE process_physical_memory_low = 1 OR process_virtual_memory_low = 1
UNION ALL
SELECT @CollectUtc, @ServerName, 'WARN', 'MEMORY', 'system_memory_state',
       system_memory_state_desc COLLATE DATABASE_DEFAULT, 2
FROM mem WHERE system_memory_state_desc <> 'Available physical memory is high'
UNION ALL
SELECT @CollectUtc, @ServerName, 'WARN', 'MEMORY', 'page_life_expectancy',
       CAST('PLE=' + CAST(ple AS varchar(20)) + ' (threshold ' + CAST(@WarnPLE AS varchar(20)) + ')' AS nvarchar(4000)) COLLATE DATABASE_DEFAULT, 2
FROM mem WHERE ple < @WarnPLE
UNION ALL
SELECT @CollectUtc, @ServerName, 'CRITICAL', 'DATABASE', name,
       CAST('state=' + state_desc AS nvarchar(4000)) COLLATE DATABASE_DEFAULT, 1
FROM sys.databases WHERE state_desc <> 'ONLINE'
UNION ALL
SELECT @CollectUtc, @ServerName, 'WARN', 'DATABASE', name,
       CAST('AUTO_SHRINK is ON' AS nvarchar(4000)) COLLATE DATABASE_DEFAULT, 2
FROM sys.databases WHERE is_auto_shrink_on = 1
UNION ALL
SELECT @CollectUtc, @ServerName, 'WARN', 'CPU', CAST('scheduler ' + CAST(scheduler_id AS varchar(10)) AS nvarchar(128)) COLLATE DATABASE_DEFAULT,
       CAST('runnable_tasks_count=' + CAST(runnable_tasks_count AS varchar(10)) AS nvarchar(4000)) COLLATE DATABASE_DEFAULT, 2
FROM sys.dm_os_schedulers
WHERE scheduler_id < 255 AND runnable_tasks_count >= @WarnRunnable
UNION ALL
SELECT @CollectUtc, @ServerName,
       CASE WHEN log_used_pct >= @CritLogUsedPct THEN 'CRITICAL' ELSE 'WARN' END,
       'LOG', database_name,
       CAST('log_used_pct=' + CAST(CAST(log_used_pct AS decimal(5,2)) AS varchar(20)) AS nvarchar(4000)) COLLATE DATABASE_DEFAULT,
       CASE WHEN log_used_pct >= @CritLogUsedPct THEN 1 ELSE 2 END
FROM #logspace
WHERE log_used_pct >= @WarnLogUsedPct
) AS alerts
ORDER BY sort_key, category, object_name;

PRINT '=== dba_instance_health_collect complete for ' + @ServerName + ' at ' + CONVERT(varchar(30), @CollectUtc, 126) + ' ===';
