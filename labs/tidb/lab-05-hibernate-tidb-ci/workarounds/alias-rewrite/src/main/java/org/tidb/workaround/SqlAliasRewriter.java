package org.tidb.workaround;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class SqlAliasRewriter {

    private static final Pattern ALIAS_BEFORE_ON_DUPLICATE = Pattern.compile(
            "(?is)(AS\\s+(\\w+)\\s*(?:\\([^)]*\\))?)\\s*(ON\\s+DUPLICATE\\s+KEY\\s+UPDATE)");

    private SqlAliasRewriter() {
    }

    static String rewrite(String sql) {
        if (sql == null) {
            return null;
        }
        String normalized = normalizeCarriageReturns(sql);
        String rewritten = dropAliasAndRewrite(normalized);
        return collapseExcessSpaces(rewritten);
    }

    private static String normalizeCarriageReturns(String sql) {
        return sql.indexOf('\r') >= 0 ? sql.replace('\r', ' ') : sql;
    }

    private static String dropAliasAndRewrite(String sql) {
        Matcher matcher = ALIAS_BEFORE_ON_DUPLICATE.matcher(sql);
        if (!matcher.find()) {
            return sql;
        }
        String alias = matcher.group(2);
        int aliasStart = matcher.start(1);
        int aliasEnd = matcher.end(1);

        StringBuilder builder = new StringBuilder(sql.length());
        builder.append(stripTrailingWhitespace(sql.substring(0, aliasStart)));
        if (builder.length() > 0 && !Character.isWhitespace(builder.charAt(builder.length() - 1))) {
            builder.append(' ');
        }

        String tail = stripLeadingWhitespace(sql.substring(aliasEnd));
        String rewrittenTail = rewriteAliasReferences(tail, alias);
        builder.append(rewrittenTail);

        String rewritten = builder.toString();
        if (!rewritten.equals(sql)) {
            System.err.printf("[AliasRewrite] Rewrote INSERT alias for TiDB compatibility%n  before: %s%n  after:  %s%n",
                    sanitize(sql), sanitize(rewritten));
        }
        return rewritten;
    }

    private static String rewriteAliasReferences(String sql, String alias) {
        Pattern aliasRef = Pattern.compile("(?i)\\b" + Pattern.quote(alias) + "\\s*\\.\\s*([A-Za-z0-9_`\"$]+)");
        Matcher matcher = aliasRef.matcher(sql);
        StringBuffer buffer = new StringBuffer();
        boolean changed = false;
        while (matcher.find()) {
            changed = true;
            String column = matcher.group(1);
            matcher.appendReplacement(buffer, "VALUES(" + column + ")");
        }
        matcher.appendTail(buffer);
        return changed ? buffer.toString() : sql;
    }

    private static String stripLeadingWhitespace(String value) {
        int idx = 0;
        while (idx < value.length() && Character.isWhitespace(value.charAt(idx))) {
            idx++;
        }
        return value.substring(idx);
    }

    private static String stripTrailingWhitespace(String value) {
        int idx = value.length() - 1;
        while (idx >= 0 && Character.isWhitespace(value.charAt(idx))) {
            idx--;
        }
        return value.substring(0, idx + 1);
    }

    private static String collapseExcessSpaces(String sql) {
        return sql.replaceAll("[ \\t]{2,}", " ");
    }

    private static String sanitize(String sql) {
        return sql.replaceAll("\\s+", " ").trim();
    }
}
