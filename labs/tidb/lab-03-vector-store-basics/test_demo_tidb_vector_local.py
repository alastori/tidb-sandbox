import os
import subprocess
import unittest
import mysql.connector
from dotenv import load_dotenv

# -------------------------
# Env / config
# -------------------------
load_dotenv()
TIDB_HOST = os.getenv("TIDB_HOST", "127.0.0.1")
TIDB_PORT = int(os.getenv("TIDB_PORT", "4000"))
TIDB_USER = os.getenv("TIDB_USER", "root")
TIDB_PASS = os.getenv("TIDB_PASSWORD", "")
TIDB_DB   = os.getenv("TIDB_DATABASE", "test-docs")

TABLE = "docs"

# -------------------------
# Helpers
# -------------------------
def connect(db: str | None = None):
    return mysql.connector.connect(
        host=TIDB_HOST, port=TIDB_PORT,
        user=TIDB_USER, password=TIDB_PASS,
        database=(db if db else None),
        ssl_disabled=True,  # local TiUP; remove for secured/cloud
    )

def quote_ident(name: str) -> str:
    return f"`{name.replace('`', '``')}`"

# -------------------------
# Tests
# -------------------------
class TestSmokeDemoTiDBVector(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Ensure the database exists for follow-up checks."""
        root = connect(None)
        cur = root.cursor()
        cur.execute(f"CREATE DATABASE IF NOT EXISTS {quote_ident(TIDB_DB)}")
        root.commit()
        cur.close(); root.close()

    def test_01_run_demo_script(self):
        """Run the demo script; pass if it exits cleanly (returncode == 0)."""
        proc = subprocess.run(
            ["python", "demo_tidb_vector_local.py"],
            capture_output=True, text=True, env=os.environ
        )
        if proc.returncode != 0:
            self.fail(
                f"demo_tidb_vector_local.py failed (code {proc.returncode})\n"
                f"STDOUT:\n{proc.stdout}\n\nSTDERR:\n{proc.stderr}"
            )

    def test_02_basic_sanity_after_run(self):
        """Minimal post-run checks: table exists, has >=5 rows, and a KNN query runs."""
        conn = connect(TIDB_DB)
        cur = conn.cursor()

        # Check table exists
        cur.execute("SHOW TABLES")
        tables = {t[0] for t in cur.fetchall()}
        self.assertIn(TABLE, tables, f"Table '{TABLE}' not found—did the demo run?")

        # Check row count
        cur.execute(f"SELECT COUNT(*) FROM {quote_ident(TABLE)}")
        (count,) = cur.fetchone()
        self.assertGreaterEqual(count, 5, f"Expected at least 5 rows in '{TABLE}', found {count}")

        # Run simple KNN query (use zero-vector to avoid needing embedder)
        zero_vec = "[" + ",".join(["0"] * 384) + "]"
        cur.execute(
            f"""
            SELECT id, title
            FROM {quote_ident(TABLE)}
            ORDER BY VEC_COSINE_DISTANCE(embedding, CAST(%s AS VECTOR))
            LIMIT 3
            """,
            (zero_vec,),
        )
        _ = cur.fetchall()  # Query executed successfully

        cur.close(); conn.close()

if __name__ == "__main__":
    unittest.main(verbosity=2)
