# Lab 04 Journal – DM vs Binlog Format

Summarize findings and test outcomes for DM under different binlog formats and versions.

## Prior Findings (carryover)

- DM v5.4 + ROW binlog: batch splits cleanly, no errors.
- DM v5.4 + STATEMENT: pauses with **36014**; `binlog skip` + revert to ROW recovers.
- DM v8.5.x + STATEMENT: task stays Running but drops DML (data divergence); start-task still requires ROW.
- Running the batch before starting the task is harmless (handled in dump); to exercise the syncer, run it after the task is running.
- Compose uses `DM_VERSION` and `MYSQL_IMAGE`; TiDB version follows the TiUP playground for that DM.

## Matrix Template (fill as you test)

| DM version | MySQL version | TiDB (playground) | binlog_format | precheck | runtime status | downstream data | notes |
|------------|---------------|-------------------|---------------|----------|----------------|-----------------|-------|
| 8.5.4 | 8.0.44 | 8.5.4 | ROW | pass | Running | rows replicated | baseline |
| 8.5.4 | 8.0.44 | 8.5.4 | STATEMENT | pass (start in ROW, then switch) | Running | table empty | DML skipped silently |
| 8.5.4 | 8.0.44 | 8.5.4 | MIXED | pass (start in ROW, then switch) | Running | table empty | mirrors STATEMENT |
| 8.5.4 | 8.0.44 | 8.5.4 | STATEMENT (ignore checks) | forced pass (`ignore-checking-items`) | Running | table empty | precheck bypassed; no 36014, DML skipped |
| 8.5.4 | 8.0.44 (binlog start=STATEMENT) | 8.5.4 | STATEMENT | fail (binlog_format is STATEMENT) | n/a | n/a | start-task blocked; precheck 26005 |
| 8.5.4 | 8.4.7 | 8.5.4 | ROW | fail (1064 SHOW MASTER STATUS) | n/a | n/a | start-task blocked; MySQL 8.4 removes SHOW MASTER STATUS |
| 8.5.4 | 8.4.7 | 8.5.4 | STATEMENT | n/a | n/a | n/a | blocked by above precheck |
| 8.5.4 | 8.4.7 | 8.5.4 | MIXED | n/a | n/a | n/a | blocked by above precheck |
| 8.1.2 | 8.0.44 | 8.1.2 | ROW | pass | Running | rows replicated | baseline |
| 8.1.2 | 8.0.44 | 8.1.2 | STATEMENT | pass (start in ROW, then switch) | Running | table empty | DML skipped silently |
| 8.1.2 | 8.0.44 | 8.1.2 | MIXED | pass (start in ROW, then switch) | Running | table empty | mirrors STATEMENT |
| 8.1.2 | 8.0.44 | 8.1.2 | STATEMENT (ignore checks) | forced pass (`ignore-checking-items`) | Running | table empty | precheck bypassed; no 36014, DML skipped |
| 8.1.2 | 8.0.44 (binlog start=STATEMENT) | 8.1.2 | STATEMENT | fail (binlog_format is STATEMENT) | n/a | n/a | start-task blocked; precheck 26005 |
| 8.1.2 | 8.4.7 | 8.1.2 | ROW | n/t | n/t | n/t | not run; expect same SHOW MASTER STATUS precheck failure |
| 8.1.2 | 8.4.7 | 8.1.2 | STATEMENT | n/t | n/t | n/t |  |
| 8.1.2 | 8.4.7 | 8.1.2 | MIXED | n/t | n/t | n/t |  |

Notes:

- **Precheck** should fail if binlog_format ≠ ROW at start-task time.
- For STATEMENT/MIXED on 8.5.4 and 8.1.2, DM stayed Running but skipped the INSERT (table existed with zero rows downstream).
- MySQL 8.4.7: start-task fails precheck (SHOW MASTER STATUS removed); even with `MYSQL_AUTH_FLAG=` and `MYSQL_SKIP_CHARSET_FLAG=` the sync cannot start.
- Forcing precheck bypass (`ignore-checking-items: ["all"]`) on 8.5.4/8.1.2 with `STATEMENT` still stayed Running and silently skipped the INSERT; no **36014** reproduced.
- Add collation/GTID quirks if observed.
