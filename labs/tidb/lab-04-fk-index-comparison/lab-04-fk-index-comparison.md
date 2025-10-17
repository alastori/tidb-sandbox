# FK and Supporting Index MySQL 8.4 & TiDB 8.5+ Comparison

This lab compares how MySQL and TiDB handle foreign keys and their supporting indexes across 4 scenarios.

## Scenarios

- **A:** Single-column FK: parent PK (names differ) **→ should succeed in both**
- **B:** Composite FK: parent UNIQUE (names differ) **→ should succeed in both**
- **C (Divergence):** Parent index is **NON-UNIQUE** on referenced columns  
  - **MySQL 8.4:** **DDL rejected** (no FK created).  
  - **TiDB 8.5.x:** **DDL accepted** (FK present) and **DML checks enforced** (bad child rejected; parent delete/update blocked).
- **D (FAIL):** Column **order mismatch** between FK and parent UNIQUE **→ rejected in both**.

## Expected Results Matrix (Empirical)

| Scenario | MySQL 8.4 | TiDB 8.5.x | Notes |
|---------:|-----------|------------|------|
| A        | ✅ success | ✅ success | Names differ; semantics match. |
| B        | ✅ success | ✅ success | Composite FK via parent UNIQUE. |
| C        | ❌ DDL rejected | ✅ DDL accepted; **DML enforced** | TiDB allows FK over non-unique parent index; MySQL does not. |
| D        | ❌ error   | ❌ error   | Column order must match. |

## How to Run

### MySQL 8.4 (Docker)

```shell
docker run -d --name mysql84 -e MYSQL_ROOT_PASSWORD=MyPassw0rd! -p 33061:3306 mysql:8.4
```

```shell
docker exec -i mysql84 mysql -uroot -pMyPassw0rd! --force --verbose < fk_lab_mysql_tidb.sql
```

### TiDB 8.5.x (tiup)

```shell
tiup playground v8.5.3 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor
```

```shell
mysql -h 127.0.0.1 -P 4000 -u root --prompt 'tidb> ' --force --verbose < fk_lab_mysql_tidb.sql
```

## Reading the Output

At the end of the SQL, you'll see **Engine Behavior Report** rows like:

- `A_fk_orders_customer_exists`: 1 (OK in both)
- `B_fk_invites_ok_exists` and `B_parent_unique_accounts_ok`: 1 (OK in both)
- `C_fk_invites_nonuniq_exists`: **0 in MySQL**, **1 in TiDB**
- `C_parent_nonunique_in_accounts_nonuniq`: 1 (confirms parent index is non-unique)
- `D_fk_invites_mismatch_exists`: 0 (rejected in both)

These let you confirm the divergence in **Scenario C** without manual interpretation.

## (Optional) TiDB Enforcement Probe for Scenario C

To validate DML enforcement under a non-unique parent key, run the **commented** probe block at the end of the SQL on TiDB only, or copy/paste this standalone probe:

```sql
USE lab_fk;
START TRANSACTION;
INSERT INTO accounts_nonuniq(account_id, org_id, email)
VALUES (2, 7, 'dup@ex.com'), (3, 7, 'dup@ex.com');

-- Negative (should FAIL): child referencing non-existent pair
-- INSERT INTO invites_nonuniq(invite_id, org_id, email) VALUES (200, 7, 'dup@ex@com');

-- Positive (should SUCCEED): exact match to parent pair
INSERT INTO invites_nonuniq(invite_id, org_id, email) VALUES (201, 7, 'dup@ex.com');

-- Delete or update a parent row (should FAIL due to child)
-- DELETE FROM accounts_nonuniq WHERE account_id = 3;
-- UPDATE accounts_nonuniq SET email='zzz@ex.com' WHERE account_id=3;

ROLLBACK;
```

## Cleanup

- Stop tiup playground with `Ctrl+C` in its terminal

- MySQL:

  ```bash
  docker rm -f mysql84
  ```

## Notes

- For cross-engine parity and predictable enforcement, define a **UNIQUE** (or **PRIMARY**) key on referenced columns for FKs.
- FK/index **names** as cosmetic; compare **columns+order**, **actions**, and check **parent key uniqueness**. 
