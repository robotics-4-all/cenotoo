FROM flink:1.18.1-scala_2.12-java11

ADD https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.0.2-1.18/flink-sql-connector-kafka-3.0.2-1.18.jar /opt/flink/lib/

EXPOSE 8081 6123 6124

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["start-cluster"]
