import java.io.StringReader;
import java.sql.*;
import java.util.Properties;

/**
 * JDBC VARCHAR(120) enforcement test against TiDB v8.5.1.
 *
 * Tests whether MySQL Connector/J can bypass VARCHAR truncation via:
 * - Server-side prepared statements (COM_STMT_PREPARE / COM_STMT_EXECUTE)
 * - COM_STMT_SEND_LONG_DATA (streaming large parameters)
 * - rewriteBatchedStatements (multi-value INSERT rewrite)
 * - setCharacterStream / setClob (streaming protocol)
 * - setString with large values
 */
public class VarcharJdbcTest {

    private static final String NONSTRICT_MODE =
        "ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES";

    private static String HOST = "host.docker.internal";
    private static int PORT = 4000;

    public static void main(String[] args) throws Exception {
        if (args.length >= 1) HOST = args[0];
        if (args.length >= 2) PORT = Integer.parseInt(args[1]);

        System.out.println("=== JDBC VARCHAR(120) Enforcement Tests ===");
        System.out.println("Target: " + HOST + ":" + PORT);

        // Print driver version
        System.out.println("Driver: MySQL Connector/J " +
            com.mysql.cj.jdbc.Driver.class.getPackage().getImplementationVersion());

        setup();

        // Test matrix
        testSetString("H41", "setString (text protocol, no server prep)", false, false);
        testSetString("H42", "setString (useServerPrepStmts=true)", true, false);
        testSetString("H43", "setString (useServerPrepStmts + rewriteBatch)", true, true);
        testSetString("H44", "setString (rewriteBatchedStatements only)", false, true);
        testSendLongData("H45", "setCharacterStream (COM_STMT_SEND_LONG_DATA)", true);
        testSendLongData("H46", "setCharacterStream (text protocol fallback)", false);
        testSetClob("H47", "setClob via StringReader (streaming)");
        testBatchInsert("H48", "addBatch/executeBatch (server prep)", true, false);
        testBatchInsert("H49", "addBatch/executeBatch (rewrite=true)", false, true);
        testBatchInsert("H50", "addBatch/executeBatch (server prep + rewrite)", true, true);
        testLargePacket("H51", "Large value near max_allowed_packet");
        testSetObject("H52", "setObject(String) via server prep", true);
        testSetNString("H53", "setNString (national character set)", true);

        System.out.println("\n=== JDBC Tests Complete ===");
    }

    private static Connection getConnection(boolean useServerPrep, boolean rewriteBatch)
            throws SQLException {
        Properties props = new Properties();
        props.setProperty("user", "root");
        props.setProperty("password", "");
        props.setProperty("useSSL", "false");
        props.setProperty("allowPublicKeyRetrieval", "true");
        if (useServerPrep) {
            props.setProperty("useServerPrepStmts", "true");
            props.setProperty("cachePrepStmts", "true");
        }
        if (rewriteBatch) {
            props.setProperty("rewriteBatchedStatements", "true");
        }
        return DriverManager.getConnection(
            "jdbc:mysql://" + HOST + ":" + PORT + "/jdbc_varchar_test", props);
    }

    private static void setup() throws SQLException {
        // Connect without database to create it first
        Properties props = new Properties();
        props.setProperty("user", "root");
        props.setProperty("password", "");
        props.setProperty("useSSL", "false");
        props.setProperty("allowPublicKeyRetrieval", "true");
        try (Connection conn = DriverManager.getConnection(
                "jdbc:mysql://" + HOST + ":" + PORT + "/", props);
             Statement stmt = conn.createStatement()) {
            stmt.execute("CREATE DATABASE IF NOT EXISTS jdbc_varchar_test");
        }
    }

    private static void freshTable(Statement stmt) throws SQLException {
        stmt.execute("DROP TABLE IF EXISTS t");
        stmt.execute("CREATE TABLE t (" +
            "id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, " +
            "nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL)");
        stmt.execute("SET SESSION sql_mode='" + NONSTRICT_MODE + "'");
    }

    private static int getMaxCharLen(Statement stmt) throws SQLException {
        try (ResultSet rs = stmt.executeQuery(
                "SELECT MAX(CHAR_LENGTH(nome)) FROM t")) {
            rs.next();
            return rs.getInt(1);
        }
    }

    private static int getOverflowCount(Statement stmt) throws SQLException {
        try (ResultSet rs = stmt.executeQuery(
                "SELECT COUNT(*) FROM t WHERE CHAR_LENGTH(nome) > 120")) {
            rs.next();
            return rs.getInt(1);
        }
    }

    private static void report(String id, String desc, int charLen) {
        System.out.printf("  %-4s %-52s -> char_len=%d%n", id, desc, charLen);
    }

    private static void report(String id, String desc, int charLen, int overflow, int total) {
        System.out.printf("  %-4s %-52s -> char_len=%d, overflow=%d/%d%n",
            id, desc, charLen, overflow, total);
    }

    // --- Test: setString with PreparedStatement ---
    private static void testSetString(String id, String desc,
            boolean useServerPrep, boolean rewriteBatch) {
        try (Connection conn = getConnection(useServerPrep, rewriteBatch);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            String bigValue = "A".repeat(500);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                ps.setString(1, bigValue);
                ps.executeUpdate();
            }

            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Test: setCharacterStream (triggers COM_STMT_SEND_LONG_DATA) ---
    private static void testSendLongData(String id, String desc, boolean useServerPrep) {
        try (Connection conn = getConnection(useServerPrep, false);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            String bigValue = "A".repeat(500);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                // setCharacterStream forces COM_STMT_SEND_LONG_DATA in binary protocol
                ps.setCharacterStream(1, new StringReader(bigValue), bigValue.length());
                ps.executeUpdate();
            }

            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Test: setClob ---
    private static void testSetClob(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            String bigValue = "A".repeat(500);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                // setClob with Reader — another path to COM_STMT_SEND_LONG_DATA
                ps.setClob(1, new StringReader(bigValue), bigValue.length());
                ps.executeUpdate();
            }

            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Test: Batch INSERT ---
    private static void testBatchInsert(String id, String desc,
            boolean useServerPrep, boolean rewriteBatch) {
        try (Connection conn = getConnection(useServerPrep, rewriteBatch);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            String bigValue = "A".repeat(500);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                for (int i = 0; i < 50; i++) {
                    ps.setString(1, bigValue);
                    ps.addBatch();
                }
                ps.executeBatch();
            }

            int total = 0;
            try (ResultSet rs = stmt.executeQuery("SELECT COUNT(*) FROM t")) {
                rs.next();
                total = rs.getInt(1);
            }

            report(id, desc, getMaxCharLen(stmt), getOverflowCount(stmt), total);
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Test: Large value near max_allowed_packet ---
    private static void testLargePacket(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            // 1MB string — well within default max_allowed_packet (64MB)
            // but large enough to potentially trigger chunked sending
            String hugeValue = "A".repeat(1_000_000);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                ps.setString(1, hugeValue);
                ps.executeUpdate();
            }

            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Test: setObject with String type ---
    private static void testSetObject(String id, String desc, boolean useServerPrep) {
        try (Connection conn = getConnection(useServerPrep, false);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            String bigValue = "A".repeat(500);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                // setObject lets the driver choose the type mapping
                ps.setObject(1, bigValue);
                ps.executeUpdate();
            }

            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Test: setNString (national character set path) ---
    private static void testSetNString(String id, String desc, boolean useServerPrep) {
        try (Connection conn = getConnection(useServerPrep, false);
             Statement stmt = conn.createStatement()) {
            freshTable(stmt);

            String bigValue = "A".repeat(500);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (nome) VALUES (?)")) {
                ps.setNString(1, bigValue);
                ps.executeUpdate();
            }

            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-52s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }
}
