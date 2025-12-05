import mysql.connector
from mysql.connector.constants import ClientFlag

# Connect to the Docker MySQL instance
conn = mysql.connector.connect(
    user="root",
    password="Pass_1234",
    host="127.0.0.1",
    port=3306,
    client_flags=[ClientFlag.MULTI_STATEMENTS],  # send the batch in a single packet
)
cursor = conn.cursor()

# 1. Create the database first with compatible collation
try:
    cursor.execute("CREATE DATABASE IF NOT EXISTS test_db CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
except:
    pass

# 2. Select the DB
cursor.execute("USE test_db")

# 3. THE CULPRIT: Sending Multi-statements in one execute call
# This mimics how some ORMs or backup scripts batch commands
print("Sending problematic SQL batch...")
sql_batch = """
CREATE TABLE IF NOT EXISTS broken_table (id INT PRIMARY KEY);
START TRANSACTION;
INSERT INTO broken_table VALUES (1);
COMMIT;
"""

# Execute as a single multi-statement batch
cursor.execute(sql_batch)
print("Number of rows affected:", cursor.rowcount)

# Consume remaining results (one per statement)
while cursor.nextset():
    if cursor.with_rows:
        print("Rows produced:", cursor.fetchall())
    else:
        print("Number of rows affected:", cursor.rowcount)

conn.close()
print("Done. Check DM status now.")
