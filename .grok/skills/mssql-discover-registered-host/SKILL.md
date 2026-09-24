---
name: mssql-discover-registered-host
description: >
  Find and verify MSSQL on a Grok Bot registered Windows machine (ListMachines,
  SQL services, port 1433, integrated SqlClient inventory). Triggers: find SQL
  on IONOS, registered host MSSQL, machine should be visible, after cloud-to-
  onprem DB move, /mssql-discover-registered-host.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# Discover MSSQL on a registered host

## When

Simon says the DB moved to a box you should already see, or you need to locate SQL without an RDS endpoint.

## Steps

1. `ListMachines` - note connected Windows hosts and machineIds.
2. On each candidate (Shell with machineId): hostname, IPv4, `Get-Service *SQL*`, registry `Instance Names\SQL`, listeners on 1433/1434.
3. Prefer full path to `SQLCMD.EXE` under Client SDK if `sqlcmd` is not on PATH; else `System.Data.SqlClient` with Integrated Security + TrustServerCertificate.
4. Inventory: `@@SERVERNAME`, edition/version, `sys.databases` (name, state, recovery_model), top user DB file paths/sizes, enabled Agent jobs (name, date_created).
5. Record machineId, public/private IPs, instance name, port, DB name in agent memory (no passwords). App SQL auth secrets stay in secret store / env names only.
6. Tell teammates who need connection shape (host/IP/port/instance) without inventing credentials.

## Success

Named machineId + instance + online user DB(s). Old cloud endpoints treated as non-primary once confirmed.

## Do not

- Echo SA or app passwords into chat or skills
- Assume named instance; default is often MSSQLSERVER on 1433
