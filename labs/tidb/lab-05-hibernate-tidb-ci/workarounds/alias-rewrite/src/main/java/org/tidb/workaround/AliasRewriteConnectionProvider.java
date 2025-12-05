package org.tidb.workaround;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.Objects;

import org.hibernate.engine.jdbc.connections.internal.DriverManagerConnectionProviderImpl;

/**
 * Quick PoC connection provider that rewrites Hibernate generated SQL so TiDB can parse
 * {@code INSERT ... AS alias \r ON DUPLICATE KEY UPDATE ...} statements.
 */
public class AliasRewriteConnectionProvider extends DriverManagerConnectionProviderImpl {

    @Override
    public Connection getConnection() throws SQLException {
        Connection delegate = super.getConnection();
        return (Connection) Proxy.newProxyInstance(
                delegate.getClass().getClassLoader(),
                new Class<?>[] { Connection.class },
                new ConnectionInvocationHandler(delegate));
    }

    @Override
    public void closeConnection(Connection conn) throws SQLException {
        super.closeConnection(unwrap(conn));
    }

    private static Connection unwrap(Connection candidate) {
        if (candidate instanceof Proxy proxy && Proxy.getInvocationHandler(proxy) instanceof ConnectionInvocationHandler handler) {
            return handler.delegate;
        }
        return candidate;
    }

    private static final class ConnectionInvocationHandler implements InvocationHandler {
        private final Connection delegate;

        ConnectionInvocationHandler(Connection delegate) {
            this.delegate = delegate;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            if (args != null && args.length > 0 && args[0] instanceof String sql && isPrepareStatement(method)) {
                Object[] cloned = Arrays.copyOf(args, args.length);
                cloned[0] = SqlAliasRewriter.rewrite(sql);
                return method.invoke(delegate, cloned);
            }
            return method.invoke(delegate, args);
        }

        private static boolean isPrepareStatement(Method method) {
            String name = method.getName();
            return "prepareStatement".equals(name) || "prepareCall".equals(name);
        }
    }
}
