import java.sql.*;
import java.io.*;
import java.util.*;
import java.util.regex.*;

/**
 * Verify TiDB setup for Hibernate ORM tests.
 *
 * Checks:
 * 1. Database connectivity (correct host/port and user authentication)
 * 2. TiDB version (v8.x LTS vs outdated v5.x)
 * 3. Required schema for Hibernate ORM tests (databases exist, dynamically calculated based on CPU count)
 * 4. TiDB-specific behavior configuration (parse bootstrap SQL and verify runtime config matches)
 */
public class VerifyTiDB {
    private static final String JDBC_URL = "jdbc:mysql://localhost:4000/hibernate_orm_test";
    private static final String USER = "hibernate_orm_test";
    private static final String PASSWORD = "hibernate_orm_test";

    private static boolean hasErrors = false;
    private static Map<String, String> expectedGlobalVars = new HashMap<>();

    public static void main(String[] args) {
        // Parse optional bootstrap SQL file argument
        String bootstrapSqlFile = null;
        if (args.length > 0) {
            bootstrapSqlFile = args[0];
        }

        // Parse bootstrap SQL to extract expected configuration
        parseBootstrapSql(bootstrapSqlFile);

        System.out.println("Verifying TiDB setup for Hibernate ORM tests...\n");

        try (Connection conn = DriverManager.getConnection(JDBC_URL, USER, PASSWORD)) {
            System.out.println("✓ Successfully connected to TiDB");

            // Check 1: Verify TiDB version
            checkVersion(conn);

            // Check 2: Verify all required databases exist (dynamically calculated)
            checkDatabases(conn);

            // Check 3: Verify TiDB-specific behavior configuration for compatibility
            checkTiDBBehaviorConfig(conn);

            // Summary
            System.out.println();
            if (hasErrors) {
                System.err.println("✗ TiDB verification completed with errors");
                System.err.println("  Please run the install script to apply fixes:");
                if (bootstrapSqlFile != null) {
                    System.err.println("  python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm \\");
                    System.err.println("    --bootstrap-sql=" + bootstrapSqlFile);
                } else {
                    System.err.println("  python3 scripts/patch_docker_db_tidb.py workspace/hibernate-orm");
                }
                System.exit(1);
            } else {
                System.out.println("✓ All TiDB verification checks passed!");
                System.out.println("  TiDB is ready for Hibernate ORM tests");
                System.exit(0);
            }

        } catch (SQLException e) {
            System.err.println("✗ Failed to connect to TiDB");
            System.err.println("  Error: " + e.getMessage());
            System.err.println();
            System.err.println("  This usually means:");
            System.err.println("  1. TiDB container is not running (run: ./docker_db.sh tidb)");
            System.err.println("  2. Bootstrap SQL failed (check docker logs tidb)");
            System.err.println("  3. Wrong network configuration (verification must use --network container:tidb)");
            System.exit(1);
        }
    }

    /**
     * Parse bootstrap SQL file to extract expected GLOBAL variable settings.
     * Looks for patterns like: SET GLOBAL variable_name=value;
     */
    private static void parseBootstrapSql(String bootstrapSqlFile) {
        if (bootstrapSqlFile == null || bootstrapSqlFile.isEmpty()) {
            return;
        }

        try (BufferedReader reader = new BufferedReader(new FileReader(bootstrapSqlFile))) {
            Pattern setGlobalPattern = Pattern.compile(
                "SET\\s+GLOBAL\\s+(\\w+)\\s*=\\s*([^;]+);?",
                Pattern.CASE_INSENSITIVE
            );

            String line;
            while ((line = reader.readLine()) != null) {
                // Skip comments and empty lines
                line = line.trim();
                if (line.isEmpty() || line.startsWith("--") || line.startsWith("#")) {
                    continue;
                }

                Matcher matcher = setGlobalPattern.matcher(line);
                if (matcher.find()) {
                    String varName = matcher.group(1);
                    String value = matcher.group(2).trim();
                    expectedGlobalVars.put(varName, value);
                }
            }
        } catch (IOException e) {
            System.err.println("⚠ Warning: Could not read bootstrap SQL file: " + bootstrapSqlFile);
            System.err.println("  Will only check base requirements");
        }
    }

    private static void checkVersion(Connection conn) {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT VERSION()")) {
            if (rs.next()) {
                String version = rs.getString(1);
                System.out.println("✓ TiDB version: " + version);

                // Check if it's TiDB (not MySQL)
                if (!version.toLowerCase().contains("tidb")) {
                    System.err.println("  ⚠ Warning: Expected TiDB, but got: " + version);
                    hasErrors = true;
                }

                // Check if it's v8.x LTS (not outdated v5.x)
                if (version.contains("TiDB")) {
                    if (version.contains("-v8.")) {
                        System.out.println("  ✓ Running recommended TiDB v8.x LTS");
                    } else if (version.contains("-v5.")) {
                        System.err.println("  ✗ Running outdated TiDB v5.x (released 2021)");
                        System.err.println("    Recommended: Update to v8.5.3 LTS");
                        System.err.println("    Set: export DB_IMAGE_TIDB=\"pingcap/tidb:v8.5.3\"");
                        hasErrors = true;
                    } else {
                        System.out.println("  ℹ Running TiDB version: " + extractTiDBVersion(version));
                    }
                }
            }
        } catch (SQLException e) {
            System.err.println("✗ Failed to check TiDB version: " + e.getMessage());
            hasErrors = true;
        }
    }

    /**
     * Check TiDB-specific behavior configuration for compatibility.
     * Dynamically checks all GLOBAL variables found in bootstrap SQL.
     */
    private static void checkTiDBBehaviorConfig(Connection conn) {
        for (Map.Entry<String, String> entry : expectedGlobalVars.entrySet()) {
            String varName = entry.getKey();
            String expectedValue = entry.getValue();
            checkGlobalVariable(conn, varName, expectedValue);
        }
    }

    private static void checkGlobalVariable(Connection conn, String varName, String expectedValue) {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT @@GLOBAL." + varName)) {
            if (rs.next()) {
                String actualValue = rs.getString(1);

                // Normalize values for comparison (handle ON/OFF, 1/0, etc.)
                boolean matches = normalizeValue(actualValue).equals(normalizeValue(expectedValue));

                if (matches) {
                    System.out.println("✓ " + varName + " = " + actualValue);
                } else {
                    System.err.println("✗ " + varName + " mismatch");
                    System.err.println("  Expected: " + expectedValue);
                    System.err.println("  Actual: " + actualValue);
                    System.err.println("  The bootstrap SQL may not have run correctly");
                    System.err.println("  Fix: rerun './docker_db.sh tidb' then '" + getVerifyCommandHint() + "'");
                    hasErrors = true;
                }
            }
        } catch (SQLException e) {
            System.err.println("✗ Failed to check " + varName + ": " + e.getMessage());
            hasErrors = true;
        }
    }

    /**
     * Normalize variable values for comparison.
     * Handles: ON/OFF, 1/0, true/false, quoted strings, etc.
     */
    private static String normalizeValue(String value) {
        if (value == null) return "";

        String v = value.trim().toLowerCase();

        // Remove quotes
        if ((v.startsWith("'") && v.endsWith("'")) || (v.startsWith("\"") && v.endsWith("\""))) {
            v = v.substring(1, v.length() - 1);
        }

        // Normalize boolean-like values
        switch (v) {
            case "on":
            case "true":
            case "yes":
                return "1";
            case "off":
            case "false":
            case "no":
                return "0";
            default:
                return v;
        }
    }

    private static void checkDatabases(Connection conn) {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SHOW DATABASES LIKE 'hibernate_orm_test%'")) {
            int count = 0;
            while (rs.next()) {
                count++;
            }

            // Calculate expected count dynamically: 1 main + (physical_cpu_count / 2)
            int expectedDbCount = getExpectedDatabaseCount();
            int expected = 1 + expectedDbCount; // hibernate_orm_test + hibernate_orm_test_1 through _N

            if (count == expected) {
                System.out.println("✓ Found " + count + " required databases (1 main + " + expectedDbCount + " additional)");
            } else {
                System.out.println("⚠ Found " + count + " databases, expected " + expected);
                System.out.println("  Expected: 1 main + " + expectedDbCount + " additional (based on CPU count)");
                System.out.println("  This is a warning only; extra/missing databases may impact test runs.");
                System.out.println("  Suggestion: keep TiDB running and rerun './docker_db.sh tidb' to reapply the bootstrap SQL,");
                System.out.println("              then rerun '" + getVerifyCommandHint() + "' if you need parity.");
            }
        } catch (SQLException e) {
            System.err.println("✗ Failed to check databases: " + e.getMessage());
            hasErrors = true;
        }
    }

    private static String getVerifyCommandHint() {
        return expectedGlobalVars.isEmpty()
            ? "./scripts/verify_tidb.sh"
            : "./scripts/verify_tidb.sh \"$WORKSPACE_DIR/tmp/patch_docker_db_tidb-last.sql\"";
    }

    /**
     * Calculate expected DB_COUNT using the same logic as docker_db.sh:
     * DB_COUNT = physical_cpu_count / 2
     *
     * This matches the upstream calculation that creates additional test databases
     * for parallel test execution.
     */
    private static int getExpectedDatabaseCount() {
        try {
            String os = System.getProperty("os.name").toLowerCase();

            if (os.contains("mac") || os.contains("darwin")) {
                // macOS: use sysctl -n hw.physicalcpu
                Process process = Runtime.getRuntime().exec(new String[]{"sysctl", "-n", "hw.physicalcpu"});
                java.io.BufferedReader reader = new java.io.BufferedReader(
                    new java.io.InputStreamReader(process.getInputStream()));
                String line = reader.readLine();
                int physicalCpus = Integer.parseInt(line.trim());
                return physicalCpus / 2;
            } else {
                // Linux: use nproc
                Process process = Runtime.getRuntime().exec(new String[]{"nproc"});
                java.io.BufferedReader reader = new java.io.BufferedReader(
                    new java.io.InputStreamReader(process.getInputStream()));
                String line = reader.readLine();
                int cpus = Integer.parseInt(line.trim());
                return cpus / 2;
            }
        } catch (Exception e) {
            // Fallback: assume 6 (typical for 12-core systems)
            System.err.println("  ⚠ Warning: Could not detect CPU count, assuming DB_COUNT=6");
            return 6;
        }
    }

    private static String extractTiDBVersion(String versionString) {
        // Extract version like "v8.5.3" from full version string
        int vIndex = versionString.indexOf("-v");
        if (vIndex >= 0) {
            int endIndex = versionString.indexOf(' ', vIndex);
            if (endIndex < 0) endIndex = versionString.length();
            return versionString.substring(vIndex + 1, endIndex);
        }
        return versionString;
    }
}
