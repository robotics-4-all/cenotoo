# Use the base image
FROM flink:1.18.1-scala_2.12-java11

# Install dependencies using native Ubuntu Python
RUN apt-get update && \
    apt-get install -y wget software-properties-common python3 python3-distutils && \
    ln -s /usr/bin/python3 /usr/bin/python && \
    wget https://bootstrap.pypa.io/get-pip.py && \
    python get-pip.py && \
    rm get-pip.py

# Install apache-flink using pip
RUN python -m pip install apache-flink==1.18.1

# Download the Flink SQL Kafka connector and the Kafka clients JAR files and place them in the required directories
RUN wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.0.2-1.18/flink-sql-connector-kafka-3.0.2-1.18.jar -P /opt/flink/lib/ && \
 cp /opt/flink/lib/flink-sql-connector-kafka-3.0.2-1.18.jar /opt/flink/
# Expose Flink ports
EXPOSE 8081 6123 6124

# Set the entrypoint to start Flink
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["start-cluster"]
