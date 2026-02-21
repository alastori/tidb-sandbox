<!-- lab-meta
archetype: manual-exploration
status: released
products: [tidb]
-->

# Lab 01 – TiDB v8.x: Base64 Decoding with `IMPORT INTO ... SET`

Test the viability of using the `IMPORT INTO ... SET` syntax with the `FROM_BASE64()` function as a powerful workaround for selectively decoding Base64-encoded columns during data import.

## Tested Environment

* **TiDB**: v8.1 (tiup playground)
* **TiUP**: v1.14.3+
* **OS**: macOS 15.5 (arm64) / Linux

## Step 1: Create the Sample Data File

This step demonstrates that the source file can contain a mix of plain text and Base64-encoded data.

* Create a file named `mixed_data.csv` in a temporary directory (e.g., `/tmp/mixed_data.csv`).

    ```csv
    1,SGVsbG8gV29ybGQh
    2,VGlE QiBpcyBhd2Vzb21lIQ==
    3,RGF0YSBJbXBvcnQ=
    ```

  * The first column is a plain integer.
  * The second column is a Base64 string.
    * `SGVsbG8gV29ybGQh` decodes to `Hello World!`
    * `VGlE QiBpcyBhd2Vzb21lIQ==` decodes to `TiDB is awesome!`
    * `RGF0YSBJbXBvcnQ=` decodes to `Data Import`

## Step 2: Start TiUP Playground

```bash
tiup playground v8.1.0 --db 1 --pd 1 --kv 1 --tiflash 0 --without-monitor
```

## Step 3: Connect to TiDB

In a new terminal, connect to the TiDB instance started by the playground.

```bash
mysql --host 127.0.0.1 --port 4000 -u root
```

## Step 4: Create the Sample Database and Table

This table will store a plain text ID and a `VARBINARY` column for the decoded Base64 data.

```sql
CREATE DATABASE base64_test;
USE base64_test;

CREATE TABLE mixed_data (
    id INT,
    encoded_data VARBINARY(255)
);
```

## Step 5: Run the `IMPORT INTO ... SET` Command

This command reads the first CSV column into the `id` table column and the second column into a user-defined variables (`@b64_data`). The `SET` clause then transforms the `@b64_data` variable with the `FROM_BASE64()` function before inserting the result into the `encoded_data` table column.

```sql
IMPORT INTO mixed_data
(id, @b64_data)
SET 
    encoded_data = FROM_BASE64(@b64_data)
FROM '/tmp/mixed_data.csv'
WITH 
    skip_rows=0;
```

> **Note:**
>
> For this to work with a local file path, the `mysql` client must be run on the same machine where the TiDB server (in this case, the `tiup playground` process) is running.

## Step 6: Verify the Data

Query the table to confirm that the data was imported and the second column was correctly decoded.

* **Query:**

    ```sql
    SELECT id, CAST(encoded_data AS CHAR) AS decoded_data FROM mixed_data;
    ```

* **Expected Output:**

    ```sql
    +------+------------------+
    | id   | secret_message   |
    +------+------------------+
    |    1 | Hello World!     |
    |    2 | TiDB is awesome! |
    |    3 | Data Import      |
    +------+------------------+
    3 rows in set (0.00 sec)
    ```

This output confirms that the `IMPORT INTO ... SET` syntax is a viable and powerful method for handling selective column transformations during import.

## Step 7: Clean Up

* You can safely delete the `/tmp/mixed_data.csv` file.
* Stop the TiUP playground by pressing `Ctrl+C` in the terminal where it is running.
