-- Flink SQL: Generic Kafka source table for ECO-READY data ingestion
-- Usage: Submit via Flink SQL Client
--   ./bin/sql-client.sh -f /path/to/kafka_source.sql
--
-- This creates a source table that reads JSON messages from Kafka topics
-- following the ECO-READY naming convention: {org}.{project}.{collection}
--
-- NOTE: Flink SQL has no native Cassandra sink connector.
-- To write to Cassandra, use one of these approaches:
--   1. Flink DataStream API with CassandraSink (Java/Scala)
--   2. JDBC sink connector (if using Cassandra with a JDBC adapter)
--   3. Keep the Python kafka-to-cassandra consumer as the bridge

CREATE TABLE kafka_source (
  `key` STRING,
  `payload` STRING,
  `topic` STRING METADATA,
  `partition` INT METADATA,
  `offset` BIGINT METADATA,
  `timestamp` TIMESTAMP(3) METADATA FROM 'timestamp',
  WATERMARK FOR `timestamp` AS `timestamp` - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kafka',
  'topic-pattern' = '.*',
  'properties.bootstrap.servers' = 'kafka1:19092,kafka2:19093',
  'properties.group.id' = 'flink_sql_consumer',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'raw'
);
