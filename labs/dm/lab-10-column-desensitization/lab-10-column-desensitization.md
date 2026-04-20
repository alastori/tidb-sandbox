<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm, mysql, tidb]
-->

# Lab-10 - Column-Level Desensitization via DM Workarounds

**Goal:** Smoke-test two workarounds for column-level data desensitization
(encryption/masking) during MySQL-to-TiDB migration via DM, since DM has no
native column-transform capability.

**Context:** A customer wants plaintext email in MySQL converted to ciphertext
after passing through DM to TiDB. DM cannot do this natively. This lab validates
whether the following workarounds are viable and documents their trade-offs.
A third scenario (downstream TiDB trigger) was considered but not included;
see "Why No Downstream Trigger Scenario?" below.

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- MySQL 8.0.44 (`mysql:8.0.44`)
- DM v8.5.4 (`pingcap/dm:v8.5.4`)
- Docker Desktop 28.5.1 on macOS 26.3.1 (arm64)
- Default password: `Pass_1234`
- Encryption: `AES-128-ECB` (pinned via `block_encryption_mode` on both engines)
- Encryption key: `lab10-secret-key` (lab-only, not production)

## Scenarios

| # | Workaround | Database | Full Load | Incremental | Encrypted in TiDB? |
|---|------------|----------|-----------|-------------|---------------------|
| S1 | Source-side MySQL trigger | `ds_s1` | encrypted | encrypted | Yes (both phases) |
| S3 | Read-time masking view | `ds_s3` | plaintext | plaintext | No (base table); masked via view |

### S1 - Source-Side Encryption (MySQL Trigger)

MySQL BEFORE INSERT/UPDATE triggers call `TO_BASE64(AES_ENCRYPT(...))` on the
email column. DM replicates the already-encrypted value. TiDB receives ciphertext
without needing any downstream logic.

**How it works (important):** The MySQL trigger fires at INSERT time, modifying
the row before it is written to storage and binlog. With `binlog_format=ROW`,
the binlog captures the **post-trigger row image** (already encrypted). DM's
dumper reads encrypted data via SELECT (full load) and DM's syncer reads
encrypted row images from the binlog (incremental). DM never "sees" the trigger;
it only replicates the resulting data. This is the key mechanism.

**Checks:**
- Full-load rows arrive as ciphertext in TiDB
- Incremental INSERT/UPDATE rows arrive as ciphertext
- `AES_DECRYPT(FROM_BASE64(email), key)` recovers plaintext in TiDB
- NULL and empty-string emails pass through unencrypted
- Long emails (200+ chars) encrypt without column truncation

**Trade-offs:**
- Cleanest approach: encryption happens at the source of truth
- Requires MySQL schema change (trigger)
- Breaks any source-side queries that expect plaintext email (e.g., `WHERE email = 'foo@bar.com'`)
- DM does NOT replicate triggers, only DML affected by them
- Idempotent on checkpoint recovery: binlog always carries encrypted value; re-insert is safe

### Why No Downstream Trigger Scenario?

Downstream TiDB triggers were considered but not tested because TiDB does not
support `CREATE TRIGGER` as of v8.5. If trigger support is added in a future
version, it could enable column-level encryption on the downstream side, but
with a full-load gap: the trigger only fires on incremental DML, not on data
loaded during the full-load phase.

### S3 - Read-Time Masking View

DM replicates plaintext to a base table. A TiDB view provides masked output
for application reads (e.g., `al****@example.com`).

**WARNING: S3 is display-level masking only, NOT a security control.** Plaintext
remains in the base table. Anyone with `SELECT` privilege on the table bypasses
the view entirely. Production use requires `REVOKE SELECT ON table` + `GRANT
SELECT ON view` for application users. Not sufficient for GDPR/PIPL compliance
without additional access controls.

**Checks:**
- Base table has plaintext (expected)
- View returns masked emails and phones
- Edge cases: NULL emails, empty strings, emails without '@', short phone numbers

**Trade-offs:**
- Simplest: no triggers, no schema changes
- Weakest: plaintext remains in the base table
- Application must use the view, not the base table
- Not true encryption; only display-level masking

## DM Configuration Notes

### import-mode: "sql" (explicit)

DM full-load defaults to SQL-based import. This generates `INSERT INTO` statements
that fire downstream triggers. If set to `"loader"` (Lightning/physical import),
TiDB Lightning bypasses the SQL layer and ingests SST files directly into TiKV,
which would NOT fire triggers. The task config pins `import-mode: "sql"` explicitly.

### safe-mode: true (explicit)

By default, DM only enables safe-mode briefly during checkpoint recovery. This lab
pins `safe-mode: true` to force `REPLACE INTO` during all incremental sync,
ensuring the REPLACE trigger interaction path is tested. In production, safe-mode
is typically left at the default (auto).

### Trigger DDL ordering (critical for S1)

MySQL triggers are created in step1, BEFORE the DM task starts in step2. DM's
binlog start position is captured at task creation. If triggers were created AFTER
the DM task started, DM would replicate the `CREATE TRIGGER` DDL to TiDB. Since
TiDB does not currently support triggers, this would cause a DM error. The ordering
in this lab prevents that. If TiDB gains trigger support in the future, the risk
becomes **double-encryption** during incremental sync (same trigger on both sides).
Production deployments must be aware of this ordering dependency.

### block_encryption_mode pinned

Both `my.cnf` and SQL sessions explicitly set `block_encryption_mode = 'aes-128-ecb'`.
MySQL 8.0 and TiDB both default to this, but a mismatch would silently produce
undecryptable data. The lab verifies this in step3.

## Edge Cases Tested

| Case | Seed Data | Expected Behavior |
|------|-----------|-------------------|
| NULL email | `(name, NULL, phone)` | Passes through unencrypted (NULL in, NULL out) |
| Empty string | `(name, '', phone)` | Passes through unmodified |
| Long email | 200-char local part | Encrypts without truncation (VARCHAR(720) column) |
| Non-ASCII chars | Email with CJK character in local part | Encrypts correctly (AES operates on bytes) |

### Column Sizing

`email VARCHAR(720)` accommodates worst-case encryption expansion:
- RFC 5321 max email: 254 bytes
- AES-128 padded: `ceil(255/16) * 16 = 256` bytes ciphertext
- BASE64 encoded: `ceil(256/3) * 4 = 344` characters
- With headroom for longer inputs up to ~512 bytes

## Prerequisites

- Docker (with Compose v2)
- `mysql` CLI client (`brew install mysql-client` on macOS, `apt install mysql-client` on Linux)
- Ports 3307, 4000, 8261 must be free (stop other DM labs first)

## Quick Start

```bash
cd labs/dm/lab-10-column-desensitization
./scripts/run-all.sh
```

## Cleanup

```bash
./scripts/step6-cleanup.sh
```

## Findings

All key questions answered affirmatively. Results from automated verdicts:

1. **Source-side trigger produces correct ciphertext.** MySQL BEFORE INSERT trigger encrypts email; binlog row image contains the ciphertext. DM replicates it faithfully.
2. **Full-load preserves encryption.** DM dumper reads already-encrypted rows via SELECT. 12/12 encrypted emails decrypt correctly on TiDB. NULL and empty-string emails pass through unmodified.
3. **Incremental safe-mode preserves encryption.** With `safe-mode: true`, DM uses `REPLACE INTO`. The binlog carries the post-trigger ciphertext, so no double-encryption occurs.
4. **Cross-engine AES round-trip works.** `block_encryption_mode` matches (`aes-128-ecb`) on both MySQL 8.0.44 and TiDB v8.5.4. `AES_DECRYPT(FROM_BASE64(...))` on TiDB recovers the original plaintext from MySQL's `AES_ENCRYPT`.
5. **S3 masking view works for all edge cases.** NULL, empty, non-ASCII, and long emails all mask correctly. Short phone numbers get full-mask to avoid leaking via LEFT/RIGHT overlap.

## Production Guidance

### Encryption mode

AES-128-ECB is **deterministic**: identical plaintexts produce identical ciphertext.
This leaks equality information (an attacker can detect duplicate emails without
decrypting). For production, use `aes-128-cbc` or `aes-128-ctr` with a per-row IV:

```sql
SET SESSION block_encryption_mode = 'aes-128-cbc';
SET @iv = RANDOM_BYTES(16);
-- Store IV alongside ciphertext
SET NEW.email_iv = TO_BASE64(@iv);
SET NEW.email = TO_BASE64(AES_ENCRYPT(NEW.email, 'key', @iv));
```

### Key management

The encryption key is hardcoded in trigger DDL, which means it is visible in:
- SQL source files (version controlled)
- `SHOW CREATE TRIGGER` output
- `information_schema.TRIGGERS` (ACTION_STATEMENT column)
- Binary log events (DDL statement)

For production, handle encryption in the application layer with proper KMS
integration. Database-side encryption with inline keys is inherently limited.

### Phone column

Phone numbers are also PII but only S3 masks them. The S1 trigger only encrypts
email. Production deployments should encrypt all PII columns or handle in the
application layer.

## References

- [DM Task Configuration](https://docs.pingcap.com/tidb/stable/task-configuration-file-full)
- [DM Safe Mode](https://docs.pingcap.com/tidb/stable/dm-safe-mode)
- [DM Expression Filter](https://docs.pingcap.com/tidb/stable/dm-key-features#expression-filter) (row filter, not column transform)
- [MySQL AES_ENCRYPT](https://dev.mysql.com/doc/refman/8.0/en/encryption-functions.html#function_aes-encrypt)
- [TiDB AES_ENCRYPT](https://docs.pingcap.com/tidb/stable/encryption-and-compression-functions#aes_encrypt)
- [MySQL Binlog Row Image](https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html#sysvar_binlog_row_image)
