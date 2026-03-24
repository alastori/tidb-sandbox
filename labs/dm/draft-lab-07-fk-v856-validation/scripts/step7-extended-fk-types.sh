#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

LOG="${RESULTS_DIR}/step7-extended-fk-${TS}.log"

{
    echo "=== Step 7: Extended FK Types (gaps F, G, H, I) ==="
    echo ""

    reset_dm_task
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/schema.sql"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/seed.sql"

    start_dm_task task-safe-single.yaml
    wait_for_sync || true
    require_mysql

    echo ""
    echo "--- S6a: Multi-level cascades (grandparent -> mid_parent -> grandchild) ---"
    echo "Executing multi-level DML..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-multi-level.sql"

    sleep 10

    echo "VALIDATION S6a: multi-level after non-key UPDATEs + DELETE grandparent 102"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'grandparent' AS _t, id, label FROM grandparent ORDER BY id;
         SELECT 'mid_parent' AS _t, id, gp_id, label FROM mid_parent ORDER BY id;
         SELECT 'grandchild' AS _t, id, mid_id, payload FROM grandchild ORDER BY id;"

    echo ""
    echo "EXPECTED S6a:"
    echo "  - grandparent 100: label='gp100:updated' (non-key UPDATE, no cascade)"
    echo "  - mid_parent 200: label='mp200:updated' (non-key UPDATE, no cascade)"
    echo "  - grandparent 102 DELETED: mid_parent 202 CASCADE-deleted, grandchild gc202a CASCADE-deleted"
    echo "  - grandparent 100,101 preserved, mid_parent 200,201 preserved, grandchild gc200a/gc200b/gc201a preserved"

    echo ""
    echo "--- S6b: ON UPDATE CASCADE semantic mismatch (gap G) ---"
    echo "Executing UK-changing UPDATE on parent_upd..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-on-update-cascade.sql"

    sleep 10

    echo "Source state (MySQL ON UPDATE CASCADE applied):"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t -e \
        "USE fk_lab;
         SELECT 'parent_upd' AS _t, id, code FROM parent_upd ORDER BY id;
         SELECT 'child_on_update' AS _t, id, parent_code, payload FROM child_on_update ORDER BY id;"

    echo ""
    echo "Target state (DM replication):"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'parent_upd' AS _t, id, code FROM parent_upd ORDER BY id;
         SELECT 'child_on_update' AS _t, id, parent_code, payload FROM child_on_update ORDER BY id;"

    echo ""
    echo "DM task status:"
    dmctl query-status fk-v856

    echo ""
    echo "EXPECTED S6b:"
    echo "  Source: parent_upd code='CODE_X', child_on_update parent_code='CODE_X' (CASCADE UPDATE)"
    echo "  Target with safe-mode:true + UK change:"
    echo "    PR #12414 rejects safe-mode PK/UK update with FK_CHECKS=1."
    echo "    Task may PAUSE with: 'safe-mode update with foreign_key_checks=1 and PK/UK changes'"
    echo "    This is the expected guardrail behavior."

    echo ""
    echo "--- S6c: Self-referencing FK (employee hierarchy, gap H) ---"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-self-ref.sql"

    sleep 10

    echo "VALIDATION S6c: self-referencing FK"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'employee' AS _t, id, name, manager_id FROM employee ORDER BY id;"

    echo ""
    echo "Source (reference):"
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t -e \
        "USE fk_lab; SELECT id, name, manager_id FROM employee ORDER BY id;"

    echo ""
    echo "EXPECTED S6c:"
    echo "  - employee 2: name='VP of Eng' (non-key UPDATE, no cascade)"
    echo "  - employee 6: exists (new INSERT)"
    echo "  - employee 3: DELETED, subordinates (id=4) get manager_id=NULL (SET NULL cascade)"
    echo "  - Self-ref FK is detected as circular; DM may skip causality (silent)"

    echo ""
    echo "--- S6d: Composite FK (multi-column, gap I) ---"
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "${LAB_DIR}/sql/dml-composite-fk.sql"

    sleep 10

    echo "VALIDATION S6d: composite FK"
    "$MYSQL_CMD" -h"$TIDB_HOST" -P"$TIDB_PORT" -uroot -t -e \
        "USE fk_lab;
         SELECT 'org' AS _t, org_id, dept_id, name FROM org ORDER BY org_id, dept_id;
         SELECT 'org_member' AS _t, id, org_id, dept_id, member_name FROM org_member ORDER BY id;"

    echo ""
    echo "EXPECTED S6d:"
    echo "  - org (1,10): name='Platform Engineering' (non-key UPDATE, no cascade)"
    echo "  - org_member Eve: exists (new INSERT with composite FK)"
    echo "  - org (1,20) DELETED: org_member Carol CASCADE-deleted"
    echo "  - Composite FK discovery correctly maps multi-column index"

    echo ""
    echo "=== Step 7 complete ==="
} 2>&1 | tee "$LOG"

clean_log "$LOG"
