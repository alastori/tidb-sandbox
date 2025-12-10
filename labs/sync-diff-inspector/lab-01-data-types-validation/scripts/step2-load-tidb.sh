#!/bin/bash
set -e

echo "=== Loading test data into TiDB ==="

MYSQL_CLIENT_IMAGE="${MYSQL_CLIENT_IMAGE:-mysql:8.0}"

# Create lab database
echo "Creating lab database..."
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot \
    -e "DROP DATABASE IF EXISTS lab; CREATE DATABASE lab;"

# Load S1-S4 scenarios
echo "Loading S1: BLOB/String/Binary family..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s1_blob_string_family.sql

echo "Loading S2: JSON..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s2_json.sql

echo "Loading S3: BIT..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s3_bit.sql

echo "Loading S4: Mixed schema..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s4_mixed.sql

# Load workaround variants (collation aligned, deterministic timestamps)
echo "Loading S1B: BLOB/String/Binary (collation aligned)..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s1b_blob_string_family_wa.sql

echo "Loading S2B: JSON (collation aligned)..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s2b_json_wa.sql

echo "Loading S4B: Mixed schema (collation aligned, fixed timestamps)..."
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot lab < sql/s4b_mixed_wa.sql

# Load S5: Sakila
echo "Loading S5: Sakila database..."
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot \
    -e "DROP DATABASE IF EXISTS sakila; CREATE DATABASE sakila;"
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot sakila < sql/s5_sakila/sakila-schema-tidb-compat.sql
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot sakila < sql/s5_sakila/sakila-data.sql

# Load S5B: Sakila workaround with TiDB-compatible schema (matches MySQL S5B)
echo "Loading S5B: Sakila (TiDB-compatible schema) on TiDB..."
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot \
    -e "DROP DATABASE IF EXISTS sakila_wa; CREATE DATABASE sakila_wa;"
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot sakila_wa < sql/s5_sakila/sakila-schema-tidb-compat-wa.sql
docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot sakila_wa < sql/s5_sakila/sakila-data-wa.sql

# Verify data loaded
echo ""
echo "=== Verification ==="
echo "Lab tables:"
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot -e "USE lab; SHOW TABLES;"
echo ""
echo "Sakila tables:"
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot -e "USE sakila; SHOW TABLES;"
echo ""
echo "Sakila_wa tables (compat schema):"
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot -e "USE sakila_wa; SHOW TABLES;"

echo ""
echo "=== TiDB data loaded successfully ==="
