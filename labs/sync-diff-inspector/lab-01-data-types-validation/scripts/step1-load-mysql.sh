#!/bin/bash
set -e

echo "=== Loading test data into MySQL ==="

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"

# Create lab database
echo "Creating lab database..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS lab; CREATE DATABASE lab;"

# Load S1-S4 scenarios
echo "Loading S1: BLOB/String/Binary family..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s1_blob_string_family.sql

echo "Loading S2: JSON..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s2_json.sql

echo "Loading S3: BIT..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s3_bit.sql

echo "Loading S4: Mixed schema..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s4_mixed.sql

# Load workaround variants (collation aligned, deterministic timestamps)
echo "Loading S1B: BLOB/String/Binary (collation aligned)..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s1b_blob_string_family_wa.sql

echo "Loading S2B: JSON (collation aligned)..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s2b_json_wa.sql

echo "Loading S4B: Mixed schema (collation aligned, fixed timestamps)..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/s4b_mixed_wa.sql

# Load S5: Sakila
echo "Loading S5: Sakila database..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS sakila; CREATE DATABASE sakila;"
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" sakila < sql/s5_sakila/sakila-schema.sql
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" sakila < sql/s5_sakila/sakila-data.sql

# Load S5B: Sakila with TiDB-compatible schema on MySQL (workaround)
echo "Loading S5B: Sakila (TiDB-compatible schema) on MySQL..."
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS sakila_wa; CREATE DATABASE sakila_wa;"
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" sakila_wa < sql/s5_sakila/sakila-schema-tidb-compat-wa.sql
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" sakila_wa < sql/s5_sakila/sakila-data-wa.sql

# Verify data loaded
echo ""
echo "=== Verification ==="
echo "Lab tables:"
docker exec mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "USE lab; SHOW TABLES;"
echo ""
echo "Sakila tables:"
docker exec mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "USE sakila; SHOW TABLES;"
echo ""
echo "Sakila_wa tables (compat schema):"
docker exec mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "USE sakila_wa; SHOW TABLES;"

echo ""
echo "=== MySQL data loaded successfully ==="
