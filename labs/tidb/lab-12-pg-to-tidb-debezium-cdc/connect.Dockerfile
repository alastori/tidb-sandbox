FROM quay.io/debezium/connect:2.5.4.Final

# Debezium image includes the PostgreSQL source connector.
# Add Confluent JDBC Sink Connector + MySQL JDBC driver for TiDB.

USER root

RUN curl -sfL -o /tmp/jdbc.zip \
    "https://d2p6pa21dvn84.cloudfront.net/api/plugins/confluentinc/kafka-connect-jdbc/versions/10.9.2/confluentinc-kafka-connect-jdbc-10.9.2.zip" && \
    unzip -q /tmp/jdbc.zip -d /kafka/connect/ && \
    rm /tmp/jdbc.zip

RUN curl -sfL -o /kafka/connect/confluentinc-kafka-connect-jdbc-10.9.2/lib/mysql-connector-j-8.3.0.jar \
    "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.3.0/mysql-connector-j-8.3.0.jar"

USER 1001
