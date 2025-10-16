import os, sys, time, json
from typing import List
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

# -------------------------
# Minimal local embeddings (fastembed, ONNXRuntime CPU)
# -------------------------
def embed_texts(texts: List[str]) -> List[List[float]]:
    try:
        from fastembed import TextEmbedding
    except Exception:
        print("pip install fastembed onnxruntime", file=sys.stderr)
        raise
    model = TextEmbedding()  # ~384-dim MiniLM; already L2-normalized
    return [e.tolist() for e in model.embed(texts)]

# -------------------------
# Helpers
# -------------------------
def connect(db: str | None = None):
    return mysql.connector.connect(
        host=TIDB_HOST, port=TIDB_PORT,
        user=TIDB_USER, password=TIDB_PASS,
        database=(db if db else None),
        ssl_disabled=True  # local TiUP; remove for secured/cloud
    )

def quote_ident(name: str) -> str:
    return f"`{name.replace('`', '``')}`"

def tiflash_present(cur) -> bool:
    cur.execute("SELECT COUNT(*) FROM information_schema.cluster_info WHERE type='tiflash'")
    (cnt,) = cur.fetchone()
    return bool(cnt and cnt > 0)

def set_tiflash_replica(cur, table: str, replicas: int = 1):
    cur.execute(f"ALTER TABLE {quote_ident(table)} SET TIFLASH REPLICA {replicas}")

def wait_for_tiflash_ready(cur, db: str, table: str, timeout_s: int = 240, poll_s: float = 2.0) -> bool:
    sql = """
      SELECT AVAILABLE
      FROM information_schema.tiflash_replica
      WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s
    """
    start = time.time()
    while True:
        cur.execute(sql, (db, table))
        row = cur.fetchone()
        if row and row[0] == 1:
            return True
        if (time.time() - start) >= timeout_s:
            return False
        time.sleep(poll_s)

# -------------------------
# Main
# -------------------------
def main():
    # 1) Create DB if missing
    root_conn = connect(None)
    root_cur = root_conn.cursor()
    root_cur.execute(f"CREATE DATABASE IF NOT EXISTS {quote_ident(TIDB_DB)}")
    root_conn.commit()
    root_cur.close(); root_conn.close()

    # 2) Connect selecting DB
    conn = connect(TIDB_DB)
    cur = conn.cursor()

    # 3) Create table (VECTOR(384))
    cur.execute("""
    CREATE TABLE IF NOT EXISTS docs (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      title VARCHAR(200),
      body TEXT,
      embedding VECTOR(384)
    )
    """)
    conn.commit()

    # 4) Ensure TiFlash exists; set replica; wait ready; add HNSW index
    use_bruteforce = False
    try:
        if tiflash_present(cur):
            set_tiflash_replica(cur, "docs", replicas=1)
            conn.commit()
            print("Waiting for TiFlash replica to become AVAILABLE ...")
            if not wait_for_tiflash_ready(cur, TIDB_DB, "docs", timeout_s=240):
                print("TiFlash replica not AVAILABLE within timeout — falling back to brute-force KNN.")
                use_bruteforce = True
            else:
                try:
                    cur.execute("""
                        ALTER TABLE docs
                          ADD VECTOR INDEX idx_docs_embedding ((VEC_COSINE_DISTANCE(embedding))) USING HNSW
                    """)
                    conn.commit()
                    print("Vector HNSW index created.")
                except mysql.connector.Error as e:
                    msg = str(e).lower()
                    if "duplicate key name" in msg or "already exists" in msg:
                        print("Vector HNSW index already exists.")
                    else:
                        print(f"Could not create vector index ({e}); falling back to brute-force KNN.")
                        use_bruteforce = True
        else:
            print("No TiFlash node detected in cluster — using brute-force KNN.")
            use_bruteforce = True
    except mysql.connector.Error as e:
        print(f"TiFlash configuration error: {e}; using brute-force KNN.")
        use_bruteforce = True

    # 5) Seed sample data
    docs = [
        ("What is TiDB?", "TiDB is a distributed MySQL-compatible database for HTAP workloads."),
        ("Vector search", "Use vector columns and HNSW indexes for semantic search."),
        ("Scalability", "TiDB scales out compute and storage for massive workloads."),
        ("Migrations", "Tools like Lightning and DM help ingest data into TiDB."),
        ("Ecosystem", "Integrate with LangChain and RAG frameworks for AI apps.")
    ]
    texts = [f"{t}. {b}" for t, b in docs]
    embs = embed_texts(texts)

    cur.execute("DELETE FROM docs")
    conn.commit()

    # INSERT — use CAST(%s AS VECTOR) with a JSON array string
    for (title, body), vec in zip(docs, embs):
        vec_json = json.dumps(vec)  # "[...]" string
        cur.execute(
            "INSERT INTO docs (title, body, embedding) VALUES (%s, %s, CAST(%s AS VECTOR))",
            (title, body, vec_json),
        )
    conn.commit()
    print("Inserted sample rows.\n")

    # 6) Query (KNN) — also CAST for the query vector
    query = "How to build semantic search in my database?"
    qvec = embed_texts([query])[0]
    qvec_json = json.dumps(qvec)

    if use_bruteforce:
        print("Running brute-force KNN (no vector index).")
    else:
        print("Running KNN using HNSW vector index.")

    cur.execute(
        """
        SELECT id, title, VEC_COSINE_DISTANCE(embedding, CAST(%s AS VECTOR)) AS score
        FROM docs
        ORDER BY score
        LIMIT 3
        """,
        (qvec_json,),
    )

    print("\nTop results:")
    for (id_, title, score) in cur.fetchall():
        print(f"- ({id_}) {title}  [score={score:.4f}]")

    cur.close(); conn.close()

if __name__ == "__main__":
    main()