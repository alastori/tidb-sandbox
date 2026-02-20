import java.io.StringReader;
import java.sql.*;
import java.util.Properties;

/**
 * Phase 7 JDBC: VARCHAR(70) enforcement on PARTITION BY KEY tables.
 * Reproduces exact gnre schema: composite PK, AUTO_ID_CACHE=1, PARTITION BY KEY.
 *
 * Tests MySQL Connector/J 9.1.0 against partitioned tables with:
 * - utf8mb4 connection charset → utf8 table charset (production mismatch)
 * - All JDBC protocol paths (text, binary, streaming, batch)
 */
public class VarcharPartitionedJdbcTest {

    private static final String NONSTRICT_MODE =
        "ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES";

    private static String HOST = "host.docker.internal";
    private static int PORT = 4000;

    public static void main(String[] args) throws Exception {
        if (args.length >= 1) HOST = args[0];
        if (args.length >= 2) PORT = Integer.parseInt(args[1]);

        System.out.println("=== Phase 7 JDBC: Partitioned Table Tests (MySQL Connector/J) ===");
        System.out.println("Target: " + HOST + ":" + PORT);
        System.out.println("Driver: MySQL Connector/J " +
            com.mysql.cj.jdbc.Driver.class.getPackage().getImplementationVersion());

        setup();

        // Section 1: Core protocol paths on partitioned VARCHAR(70)
        testSetString("J1", "setString (text, no prep) — partitioned", false, false);
        testSetString("J2", "setString (serverPrepStmts) — partitioned", true, false);
        testSetString("J3", "setString (prep + rewriteBatch) — partitioned", true, true);
        testSetString("J4", "setString (rewriteBatch only) — partitioned", false, true);
        testSendLongData("J5", "setCharacterStream (LONG_DATA) — partitioned", true);
        testSendLongData("J6", "setCharacterStream (text) — partitioned", false);
        testSetClob("J7", "setClob StringReader — partitioned");

        // Section 2: Batch operations across partitions
        testBatchInsert("J8", "executeBatch (prep, 50 rows) — partitioned", true, false);
        testBatchInsert("J9", "executeBatch (rewrite, 50) — partitioned", false, true);
        testBatchInsert("J10", "executeBatch (prep+rewrite, 50) — partitioned", true, true);

        // Section 3: Edge cases
        testLargePacket("J11", "1MB string via server prep — partitioned");
        testSetObject("J12", "setObject(String) — partitioned");
        testSetNString("J13", "setNString — partitioned");

        // Section 4: Connection charset variations
        testCharsetVariation("J14", "characterEncoding=UTF-8 — partitioned", "UTF-8");
        testCharsetVariation("J15", "characterEncoding=latin1 — partitioned", "latin1");

        // Section 5: Multi-empresa batch (different partition targets)
        testMultiPartitionBatch("J16", "batch across 20 partitions (serverPrep)", true);
        testMultiPartitionBatch("J17", "batch across 20 partitions (rewrite)", false);

        // Section 6: Full gnre schema with all columns
        testFullGnreSchema("J18", "full gnre schema INSERT — JDBC");

        System.out.println("\n=== Phase 7 JDBC Tests Complete ===");
    }

    private static Connection getConnection(boolean useServerPrep, boolean rewriteBatch)
            throws SQLException {
        Properties props = new Properties();
        props.setProperty("user", "root");
        props.setProperty("password", "");
        props.setProperty("useSSL", "false");
        props.setProperty("allowPublicKeyRetrieval", "true");
        props.setProperty("characterEncoding", "UTF-8");
        if (useServerPrep) {
            props.setProperty("useServerPrepStmts", "true");
            props.setProperty("cachePrepStmts", "true");
        }
        if (rewriteBatch) {
            props.setProperty("rewriteBatchedStatements", "true");
        }
        return DriverManager.getConnection(
            "jdbc:mysql://" + HOST + ":" + PORT + "/phase7_jdbc", props);
    }

    private static Connection getConnectionWithCharset(String charset) throws SQLException {
        Properties props = new Properties();
        props.setProperty("user", "root");
        props.setProperty("password", "");
        props.setProperty("useSSL", "false");
        props.setProperty("allowPublicKeyRetrieval", "true");
        props.setProperty("useServerPrepStmts", "true");
        props.setProperty("characterEncoding", charset);
        return DriverManager.getConnection(
            "jdbc:mysql://" + HOST + ":" + PORT + "/phase7_jdbc", props);
    }

    private static void setup() throws SQLException {
        Properties props = new Properties();
        props.setProperty("user", "root");
        props.setProperty("password", "");
        props.setProperty("useSSL", "false");
        props.setProperty("allowPublicKeyRetrieval", "true");
        try (Connection conn = DriverManager.getConnection(
                "jdbc:mysql://" + HOST + ":" + PORT + "/", props);
             Statement stmt = conn.createStatement()) {
            stmt.execute("DROP DATABASE IF EXISTS phase7_jdbc");
            stmt.execute("CREATE DATABASE phase7_jdbc DEFAULT CHARSET utf8 COLLATE utf8_general_ci");
        }
    }

    private static void freshPartitionedTable(Statement stmt) throws SQLException {
        stmt.execute("DROP TABLE IF EXISTS t");
        stmt.execute("CREATE TABLE t (" +
            "id BIGINT NOT NULL AUTO_INCREMENT, " +
            "idEmpresa BIGINT NOT NULL, " +
            "enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL, " +
            "PRIMARY KEY (id, idEmpresa)" +
            ") AUTO_ID_CACHE 1 " +
            "PARTITION BY KEY (idEmpresa) PARTITIONS 128");
        stmt.execute("SET SESSION sql_mode='" + NONSTRICT_MODE + "'");
    }

    private static int getMaxCharLen(Statement stmt) throws SQLException {
        try (ResultSet rs = stmt.executeQuery(
                "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t")) {
            rs.next();
            return rs.getInt(1);
        }
    }

    private static int getOverflowCount(Statement stmt) throws SQLException {
        try (ResultSet rs = stmt.executeQuery(
                "SELECT COUNT(*) FROM t WHERE CHAR_LENGTH(enderecoDestinatario) > 70")) {
            rs.next();
            return rs.getInt(1);
        }
    }

    private static void report(String id, String desc, int charLen) {
        System.out.printf("  %-4s %-55s -> char_len=%d%n", id, desc, charLen);
    }

    private static void report(String id, String desc, int charLen, int overflow, int total) {
        System.out.printf("  %-4s %-55s -> char_len=%d, overflow=%d/%d%n",
            id, desc, charLen, overflow, total);
    }

    // --- setString ---
    private static void testSetString(String id, String desc,
            boolean useServerPrep, boolean rewriteBatch) {
        try (Connection conn = getConnection(useServerPrep, rewriteBatch);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setString(2, bigValue);
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- setCharacterStream ---
    private static void testSendLongData(String id, String desc, boolean useServerPrep) {
        try (Connection conn = getConnection(useServerPrep, false);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setCharacterStream(2, new StringReader(bigValue), bigValue.length());
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- setClob ---
    private static void testSetClob(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setClob(2, new StringReader(bigValue), bigValue.length());
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Batch INSERT across partitions ---
    private static void testBatchInsert(String id, String desc,
            boolean useServerPrep, boolean rewriteBatch) {
        try (Connection conn = getConnection(useServerPrep, rewriteBatch);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                for (int i = 0; i < 50; i++) {
                    ps.setLong(1, (i + 1) * 1000L); // different partitions
                    ps.setString(2, bigValue);
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
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Large packet ---
    private static void testLargePacket(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String hugeValue = "A".repeat(1_000_000);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setString(2, hugeValue);
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- setObject ---
    private static void testSetObject(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setObject(2, bigValue);
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- setNString ---
    private static void testSetNString(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setNString(2, bigValue);
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- charset variation ---
    private static void testCharsetVariation(String id, String desc, String charset) {
        try (Connection conn = getConnectionWithCharset(charset);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                ps.setLong(1, 12345);
                ps.setString(2, bigValue);
                ps.executeUpdate();
            }
            report(id, desc, getMaxCharLen(stmt));
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Multi-partition batch (different idEmpresa per row) ---
    private static void testMultiPartitionBatch(String id, String desc, boolean useServerPrep) {
        try (Connection conn = getConnection(useServerPrep, !useServerPrep);
             Statement stmt = conn.createStatement()) {
            freshPartitionedTable(stmt);
            String bigValue = "A".repeat(200);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)")) {
                for (int i = 0; i < 20; i++) {
                    ps.setLong(1, (i + 1) * 7919L); // prime spacing for partition spread
                    ps.setString(2, bigValue);
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
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }

    // --- Full gnre schema ---
    private static void testFullGnreSchema(String id, String desc) {
        try (Connection conn = getConnection(true, false);
             Statement stmt = conn.createStatement()) {
            stmt.execute("DROP TABLE IF EXISTS gnre_jdbc");
            stmt.execute("CREATE TABLE gnre_jdbc (" +
                "id BIGINT NOT NULL AUTO_INCREMENT, " +
                "idEmpresa BIGINT NOT NULL, " +
                "c01_UfFavorecida CHAR(2) COLLATE utf8_general_ci NOT NULL, " +
                "c02_receita VARCHAR(6) COLLATE utf8_general_ci NOT NULL, " +
                "c26_produto INT NOT NULL, " +
                "CNPJ VARCHAR(14) COLLATE utf8_general_ci NOT NULL, " +
                "c28_tipoDocOrigem INT NOT NULL, " +
                "c04_docOrigem VARCHAR(18) COLLATE utf8_general_ci NOT NULL, " +
                "c10_valorTotal DECIMAL(15,2) NOT NULL, " +
                "c14_dataVencimento DATE NOT NULL, " +
                "c16_razaoSocialEmitente VARCHAR(100) COLLATE utf8_general_ci NOT NULL, " +
                "c18_enderecoEmitente VARCHAR(100) COLLATE utf8_general_ci NOT NULL, " +
                "c19_municipioEmitente VARCHAR(5) COLLATE utf8_general_ci NOT NULL, " +
                "municipio VARCHAR(100) COLLATE utf8_general_ci NOT NULL, " +
                "c20_ufEnderecoEmitente CHAR(2) COLLATE utf8_general_ci NOT NULL, " +
                "c21_cepEmitente VARCHAR(8) COLLATE utf8_general_ci NOT NULL, " +
                "c22_telefoneEmitente VARCHAR(11) COLLATE utf8_general_ci NOT NULL, " +
                "c33_dataPagamento DATE NOT NULL, " +
                "dataCriacao DATETIME NOT NULL, " +
                "dataAlteracao DATETIME NOT NULL, " +
                "chaveAcesso VARCHAR(44) COLLATE utf8_general_ci NOT NULL, " +
                "idOrigem BIGINT NOT NULL, " +
                "tipoOrigem VARCHAR(15) COLLATE utf8_general_ci NOT NULL, " +
                "c37_razaoSocialDestinatario VARCHAR(60) COLLATE utf8_general_ci NOT NULL, " +
                "c38_municipioDestinatario VARCHAR(5) COLLATE utf8_general_ci NOT NULL, " +
                "municipioDestinatario VARCHAR(100) COLLATE utf8_general_ci NOT NULL, " +
                "CNPJDestinatario VARCHAR(14) COLLATE utf8_general_ci NOT NULL, " +
                "situacao TINYINT NOT NULL DEFAULT '1', " +
                "valor_fcp DECIMAL(15,2) NOT NULL, " +
                "protocolo VARCHAR(25) COLLATE utf8_general_ci NOT NULL, " +
                "codigoBarras VARCHAR(48) COLLATE utf8_general_ci NOT NULL, " +
                "numeroControle VARCHAR(25) COLLATE utf8_general_ci NOT NULL, " +
                "idContato BIGINT NOT NULL, " +
                "cepDestinatario VARCHAR(8) COLLATE utf8_general_ci NOT NULL, " +
                "dataEmissaoDoc DATETIME NOT NULL, " +
                "enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL, " +
                "c15_convenio VARCHAR(30) COLLATE utf8_general_ci NOT NULL, " +
                "c25_detalhamentoReceita VARCHAR(6) COLLATE utf8_general_ci NOT NULL, " +
                "c36_inscricaoEstadualDestinatario VARCHAR(16) COLLATE utf8_general_ci NOT NULL DEFAULT '', " +
                "excluido TINYINT NOT NULL DEFAULT '0', " +
                "inscricaoEstadualEmitente VARCHAR(16) COLLATE utf8_general_ci NOT NULL DEFAULT '', " +
                "PRIMARY KEY (id, idEmpresa), " +
                "KEY idContato (idContato), " +
                "KEY idEmpresaExcluido (idEmpresa, excluido), " +
                "KEY idEmpresaIdOrigemTipoOrigem (idEmpresa, idOrigem, tipoOrigem), " +
                "KEY idEmpresaDataVencimento (idEmpresa, c14_dataVencimento)" +
                ") ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci " +
                "AUTO_ID_CACHE 1 PARTITION BY KEY (idEmpresa) PARTITIONS 128");
            stmt.execute("SET SESSION sql_mode='" + NONSTRICT_MODE + "'");

            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO gnre_jdbc (idEmpresa, c01_UfFavorecida, c02_receita, " +
                    "c26_produto, CNPJ, c28_tipoDocOrigem, c04_docOrigem, c10_valorTotal, " +
                    "c14_dataVencimento, c16_razaoSocialEmitente, c18_enderecoEmitente, " +
                    "c19_municipioEmitente, municipio, c20_ufEnderecoEmitente, c21_cepEmitente, " +
                    "c22_telefoneEmitente, c33_dataPagamento, dataCriacao, dataAlteracao, " +
                    "chaveAcesso, idOrigem, tipoOrigem, c37_razaoSocialDestinatario, " +
                    "c38_municipioDestinatario, municipioDestinatario, CNPJDestinatario, " +
                    "valor_fcp, protocolo, codigoBarras, numeroControle, idContato, " +
                    "cepDestinatario, dataEmissaoDoc, enderecoDestinatario, c15_convenio, " +
                    "c25_detalhamentoReceita) VALUES " +
                    "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")) {
                ps.setLong(1, 12345);
                ps.setString(2, "SP");
                ps.setString(3, "100236");
                ps.setInt(4, 0);
                ps.setString(5, "12345678901234");
                ps.setInt(6, 10);
                ps.setString(7, "123456789012345678");
                ps.setBigDecimal(8, new java.math.BigDecimal("150.00"));
                ps.setDate(9, java.sql.Date.valueOf("2026-02-28"));
                ps.setString(10, "X".repeat(100));
                ps.setString(11, "Y".repeat(100));
                ps.setString(12, "12345");
                ps.setString(13, "Z".repeat(100));
                ps.setString(14, "SP");
                ps.setString(15, "12345678");
                ps.setString(16, "11987654321");
                ps.setDate(17, java.sql.Date.valueOf("2026-02-20"));
                ps.setTimestamp(18, new java.sql.Timestamp(System.currentTimeMillis()));
                ps.setTimestamp(19, new java.sql.Timestamp(System.currentTimeMillis()));
                ps.setString(20, "K".repeat(44));
                ps.setLong(21, 999);
                ps.setString(22, "NF");
                ps.setString(23, "D".repeat(60));
                ps.setString(24, "54321");
                ps.setString(25, "M".repeat(100));
                ps.setString(26, "98765432101234");
                ps.setBigDecimal(27, new java.math.BigDecimal("10.00"));
                ps.setString(28, "P".repeat(25));
                ps.setString(29, "B".repeat(48));
                ps.setString(30, "N".repeat(25));
                ps.setLong(31, 1);
                ps.setString(32, "87654321");
                ps.setTimestamp(33, new java.sql.Timestamp(System.currentTimeMillis()));
                ps.setString(34, "A".repeat(200)); // oversized!
                ps.setString(35, "C".repeat(30));
                ps.setString(36, "100236");
                ps.executeUpdate();
            }

            try (ResultSet rs = stmt.executeQuery(
                    "SELECT CHAR_LENGTH(enderecoDestinatario) FROM gnre_jdbc")) {
                rs.next();
                report(id, desc, rs.getInt(1));
            }
        } catch (Exception e) {
            System.out.printf("  %-4s %-55s -> ERROR: %s%n", id, desc, e.getMessage());
        }
    }
}
