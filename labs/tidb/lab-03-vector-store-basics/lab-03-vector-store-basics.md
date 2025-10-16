# Lab-03 — TiDB Vector Store Basics: VECTOR Columns, TiFlash, and HNSW Indexes

**Goal:** Demonstrate TiDB's native vector search capabilities, including the `VECTOR` data type, TiFlash replicas for vector indexes, HNSW index creation, and KNN queries using `VEC_COSINE_DISTANCE`.

## Tested Environment

* **TiDB 8.5.3** — via `tiup playground`
* **Python 3.x** — with `fastembed`, `mysql-connector-python`, `python-dotenv`

## Step 0 — Start TiDB Playground with TiFlash

TiDB's vector indexes (HNSW) require a **TiFlash** node. Start the playground with TiFlash enabled:

```shell
tiup playground v8.5.3 --db 1 --pd 1 --kv 1 --tiflash 1 --without-monitor
```

* Output:

  ```shell
  Start pd instance: v8.5.3
  Start tikv instance: v8.5.3
  Start tidb instance: v8.5.3
  Waiting for tidb instances ready
  - TiDB: 127.0.0.1:4000 ... Done
  Start tiflash instance: v8.5.3
  Waiting for tiflash instances ready
  - TiFlash: 127.0.0.1:3930 ... Done

  🎉 TiDB Playground Cluster is started, enjoy!

  Connect TiDB:    mysql --host 127.0.0.1 --port 4000 -u root
  TiDB Dashboard:  http://127.0.0.1:2379/dashboard
  ```

> **Note:** The `--tiflash 1` flag is critical. Without TiFlash, you cannot create HNSW vector indexes and must fall back to brute-force KNN queries.

## Step 1 — Set Up Python Environment

The demo uses a Python script with local embeddings (fastembed) to generate vector representations of text documents.

* Create and activate a virtual environment:

  ```shell
  python3 -m venv .venv
  source .venv/bin/activate
  ```

* Install dependencies:

  ```shell
  pip install fastembed mysql-connector-python python-dotenv onnxruntime
  ```

* Create a `.env` file (or copy from `.env-example`) with your TiDB connection details:

  ```ini
  TIDB_HOST=127.0.0.1
  TIDB_PORT=4000
  TIDB_USER=root
  TIDB_PASSWORD=
  TIDB_DATABASE=test-docs
  ```

## Step 2 — Understanding the VECTOR Data Type

TiDB 8.5+ supports the `VECTOR` data type for storing high-dimensional embeddings:

```sql
CREATE TABLE docs (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  title VARCHAR(200),
  body TEXT,
  embedding VECTOR(384)  -- 384-dimensional vector
);
```

* **Syntax**: `VECTOR(N)` where `N` is the dimensionality (e.g., 384 for MiniLM embeddings, 1536 for OpenAI ada-002)
* **Storage**: Vectors are stored efficiently in TiFlash columnar format
* **Operations**: Use `VEC_COSINE_DISTANCE()`, `VEC_L2_DISTANCE()`, `VEC_NEGATIVE_INNER_PRODUCT()` for similarity search

## Step 3 — Run the Demo Script

The demo script (`demo_tidb_vector_local.py`) performs the following TiDB operations:

1. Creates the database and table with a `VECTOR(384)` column
2. Configures a TiFlash replica for the table
3. Creates an HNSW vector index on the embedding column
4. Inserts sample documents with their vector embeddings
5. Executes a KNN query using `VEC_COSINE_DISTANCE`

* Run the script:

  ```shell
  python demo_tidb_vector_local.py
  ```

* Output:

  ```shell
  Waiting for TiFlash replica to become AVAILABLE ...
  Vector HNSW index created.
  Inserted sample rows.

  Running KNN using HNSW vector index.

  Top results:
  - (2) Vector search  [score=0.2573]
  - (4) Migrations  [score=0.3561]
  - (5) Ecosystem  [score=0.3789]
  ```

### What Happened in TiDB

#### 1. TiFlash Replica Configuration

```sql
ALTER TABLE docs SET TIFLASH REPLICA 1;
```

* This creates a columnar replica of the table in TiFlash
* Required for creating HNSW vector indexes
* The script waits for the replica to become `AVAILABLE` by checking:

```sql
SELECT AVAILABLE
FROM information_schema.tiflash_replica
WHERE TABLE_SCHEMA='test-docs' AND TABLE_NAME='docs';
```

#### 2. HNSW Vector Index Creation

```sql
ALTER TABLE docs
  ADD VECTOR INDEX idx_docs_embedding ((VEC_COSINE_DISTANCE(embedding)))
  USING HNSW;
```

* **HNSW** (Hierarchical Navigable Small World) is an approximate nearest neighbor (ANN) algorithm
* Dramatically faster than brute-force KNN for large datasets
* The index is built on the `VEC_COSINE_DISTANCE` distance function
* Only works when a TiFlash replica exists

#### 3. Inserting Vectors

Vectors are inserted using `CAST` with a JSON array representation:

```sql
INSERT INTO docs (title, body, embedding)
VALUES ('Vector search', 'Use vector columns...', CAST('[0.1, 0.2, ...]' AS VECTOR));
```

* The Python script generates embeddings using fastembed (384-dim MiniLM model)
* Vectors are serialized as JSON arrays and cast to `VECTOR` type

#### 4. KNN Query with VEC_COSINE_DISTANCE

```sql
SELECT id, title, VEC_COSINE_DISTANCE(embedding, CAST('[...]' AS VECTOR)) AS score
FROM docs
ORDER BY score
LIMIT 3;
```

* `VEC_COSINE_DISTANCE(v1, v2)` computes the cosine distance: `1 - cosine_similarity`
* **Lower scores = more similar** (0 = identical vectors)
* The query vector is also cast from a JSON array
* With the HNSW index, this query uses the approximate index for fast retrieval

## Step 4 — Verify with Unit Tests

The lab includes unit tests to validate the setup:

* Run the test suite:

  ```shell
  python -m unittest -v test_demo_tidb_vector_local.py
  ```

* Output:

  ```shell
  test_01_run_demo_script (test_demo_tidb_vector_local.TestSmokeDemoTiDBVector.test_01_run_demo_script)
  Run the demo script; pass if it exits cleanly (returncode == 0). ... ok
  test_02_basic_sanity_after_run (test_demo_tidb_vector_local.TestSmokeDemoTiDBVector.test_02_basic_sanity_after_run)
  Minimal post-run checks: table exists, has >=5 rows, and a KNN query runs. ... ok

  ----------------------------------------------------------------------
  Ran 2 tests in 2.529s

  OK
  ```

The tests verify:

1. The demo script runs successfully
2. The table was created with at least 5 rows
3. KNN queries execute without errors

## Step 5 — Explore with MySQL Client

Connect to TiDB and inspect the vector-enabled table:

* Connect:

  ```shell
  mysql --host 127.0.0.1 --port 4000 -u root -D test-docs --prompt 'tidb> '
  ```

* Check table structure:

  ```sql
  DESCRIBE docs;
  ```

* Output:

    ```sql
    +-----------+--------------+------+------+---------+----------------+
    | Field     | Type         | Null | Key  | Default | Extra          |
    +-----------+--------------+------+------+---------+----------------+
    | id        | bigint       | NO   | PRI  | NULL    | auto_increment |
    | title     | varchar(200) | YES  |      | NULL    |                |
    | body      | text         | YES  |      | NULL    |                |
    | embedding | vector(384)  | YES  |      | NULL    |                |
    +-----------+--------------+------+------+---------+----------------+
    ```

* Check TiFlash replica status:

  ```sql
  SELECT TABLE_NAME, AVAILABLE, PROGRESS
  FROM information_schema.tiflash_replica
  WHERE TABLE_SCHEMA='test-docs';
  ```

* Output:

    ```sql
    +------------+-----------+----------+
    | TABLE_NAME | AVAILABLE | PROGRESS |
    +------------+-----------+----------+
    | docs       |         1 |        1 |
    +------------+-----------+----------+
    ```

  > `AVAILABLE = 1` means the TiFlash replica is ready

* Check vector indexes:

  ```sql
  SHOW INDEX FROM docs\G
  ```

* Output:

    ```sql
    *************************** 1. row ***************************
            Table: docs
    Non_unique: 0
        Key_name: PRIMARY
    Seq_in_index: 1
    Column_name: id
        Collation: A
    Cardinality: 0
        Sub_part: NULL
        Packed: NULL
            Null: 
    Index_type: BTREE
        Comment: 
    Index_comment: 
        Visible: YES
    Expression: NULL
        Clustered: YES
        Global: NO
    *************************** 2. row ***************************
            Table: docs
    Non_unique: 1
        Key_name: idx_docs_embedding
    Seq_in_index: 1
    Column_name: embedding
        Collation: A
    Cardinality: 0
        Sub_part: NULL
        Packed: NULL
            Null: YES
    Index_type: HNSW
        Comment: 
    Index_comment: 
        Visible: YES
    Expression: NULL
        Clustered: NO
        Global: NO
    2 rows in set (0.001 sec)
    ```

* Run a manual KNN query (using the embedding from the first row as the query vector for simplicity):

  ```sql
  SET @q = (SELECT embedding FROM docs WHERE title = 'What is TiDB?' LIMIT 1);

  SELECT id, title,
        VEC_COSINE_DISTANCE(embedding, @q) AS score
  FROM docs ORDER BY score LIMIT 3;
  ```

* Output:

    ```sql
    +----+---------------+--------------------+
    | id | title         | score              |
    +----+---------------+--------------------+
    |  6 | What is TiDB? |                  0 |
    |  9 | Migrations    | 0.2888207104267694 |
    |  8 | Scalability   | 0.3006586074043781 |
    +----+---------------+--------------------+
    ```

* Quit:

  ```sql
  quit
  ```

## Summary

### TiDB Vector Search Features

| Feature | Description |
|---------|-------------|
| **VECTOR Data Type** | Native support for high-dimensional embeddings (e.g., `VECTOR(384)`, `VECTOR(1536)`) |
| **TiFlash Requirement** | Vector indexes require a TiFlash columnar replica |
| **HNSW Index** | Approximate nearest neighbor (ANN) index for fast KNN queries |
| **Distance Functions** | `VEC_COSINE_DISTANCE`, `VEC_L2_DISTANCE`, `VEC_NEGATIVE_INNER_PRODUCT` |
| **JSON Integration** | Vectors can be inserted/queried using JSON array format with `CAST` |
| **Fallback Path** | Graceful degradation to brute-force KNN if TiFlash/HNSW unavailable |

### When to Use Vector Indexes

* **Recommended**: Datasets with >10,000 vectors where query latency matters
* **HNSW Benefits**: Logarithmic query time vs linear (brute-force)
* **Trade-offs**: HNSW is approximate (may miss exact nearest neighbors in exchange for speed)
* **Requirements**: TiFlash node + columnar replica + sufficient memory

### Use Cases

* **Semantic Search**: Find documents similar to a query based on meaning (not keywords)
* **Recommendation Systems**: Find similar products, users, or content
* **RAG Applications**: Retrieve relevant context for LLM prompts
* **Anomaly Detection**: Identify outliers in high-dimensional spaces

## Step 6 — Clean Up

* Stop the TiDB playground with `Ctrl+C` (remove the database).

* Deactivate the virtual environment:

  ```shell
  deactivate
  ```

## Conclusion

This lab demonstrated TiDB's native vector search capabilities:

1. **VECTOR data type** for storing embeddings
2. **TiFlash replicas** required for vector indexes
3. **HNSW indexes** for fast approximate KNN queries
4. **VEC_COSINE_DISTANCE** for similarity search
5. **Fallback mechanisms** when TiFlash/HNSW unavailable

TiDB's vector support enables building AI-powered applications (RAG, semantic search, recommendations) directly in the database, eliminating the need for separate vector databases.
