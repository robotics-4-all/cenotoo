# **ECO-READY Infrastructure**

A distributed system setup consisting of Kafka, Cassandra, Flink, ksqlDB, and custom consumers, designed to run across **two nodes** for high availability and scalability.

---

## **Table of Contents**
1. [System Architecture](#system-architecture)
2. [Prerequisites](#prerequisites)
3. [Cloning the Repository](#cloning-the-repository)
4. [Environment Configuration](#environment-configuration)
5. [Deployment Instructions](#deployment-instructions)
   - [Generate Kafka Cluster ID](#generate-kafka-cluster-id)
   - [Node 1 Setup](#node-1-setup)
   - [Node 2 Setup](#node-2-setup)
6. [Initializing Cassandra](#initializing-cassandra)
7. [Additional Notes](#additional-notes)

---

## **System Architecture**

This system consists of:
1. **Node 1**:
   - Kafka Broker 1
   - Cassandra Node 1
   - Flink JobManager 1
   - Flink TaskManager 1
   - Zookeeper Node 1
   - ksqlDB Server 1 

2. **Node 2**:
   - Kafka Broker 2
   - Cassandra Node 2
   - Flink JobManager 2
   - Flink TaskManager 2
   - Zookeeper Nodes 2 and 3
   - ksqlDB Server 2

Custom consumers (`kafka-to-cassandra` and `flink-to-cassandra`) can run on either or both nodes.

---

## **Prerequisites**

Ensure the following are installed on **both nodes**:
- **Docker** (>= 20.10)
- **Docker Compose** (>= 1.29)
- **Python** (>= 3.8)
- **pip** (for Python dependencies)

---

## **Cloning the Repository**

On **both nodes**, clone the GitHub repository:
```
git clone https://github.com/AuthEceSoftEng/ecoready-observatory.git
cd infrastructure
```

---

## **Environment Configuration**

1. **Create `.env` File**:
   - On both nodes, copy the example environment file:
     ```
     cp .env.example .env
     ```
   - Update the variables specific to each node.

2. **Example `.env` for Node 1**:
   ```
   KAFKA_BROKER1_IP=192.168.1.101
   KAFKA_BROKER2_IP=192.168.1.102
   CASSANDRA_SEEDS=192.168.1.101,192.168.1.102
   CASSANDRA_BROADCAST_ADDRESS1=192.168.1.101
   ZOOKEEPER1_IP=192.168.1.101
   JOBMANAGER1_IP=192.168.1.201
   TASKMANAGER1_IP=192.168.1.202
   ```

3. **Example `.env` for Node 2**:
   ```
   KAFKA_BROKER1_IP=192.168.1.101
   KAFKA_BROKER2_IP=192.168.1.102
   CASSANDRA_SEEDS=192.168.1.101,192.168.1.102
   CASSANDRA_BROADCAST_ADDRESS2=192.168.1.102
   ZOOKEEPER2_IP=192.168.1.102
   ZOOKEEPER3_IP=192.168.1.103
   JOBMANAGER2_IP=192.168.2.201
   TASKMANAGER2_IP=192.168.2.202
   ```

---

## **Deployment Instructions**

### **Generate Kafka Cluster ID**

1. On one of the nodes, run the provided script to generate the Kafka Cluster ID:
   ```
   python scripts/generate-cluster-id.py
   ```

2. Copy the generated Cluster ID and update the `.env` file on **both nodes**:
   ```
   KAFKA_CLUSTER_ID=<generated-cluster-id>
   ```

---

### **Node 1 Setup**

1. Navigate to the project directory on Node 1.
2. Build the Docker images:
   ```
   bash scripts/build-images.sh
   ```
3. Run the containers for Node 1:
   ```
   docker-compose up -d kafka1 cassandra1 jobmanager1 taskmanager1 zoo1 ksqldb-server1
   ```

---

### **Node 2 Setup**

1. Navigate to the project directory on Node 2.
2. Build the Docker images:
   ```
   bash scripts/build-images.sh
   ```
3. Run the containers for Node 2:
   ```
   docker-compose up -d kafka2 cassandra2 jobmanager2 taskmanager2 zoo2 zoo3 ksqldb-server2
   ```

---

## **Initializing Cassandra**

1. Install Cassandra dependencies:
   ```
   pip install -r requirements.txt
   ```
2. Run the Cassandra initialization script on **one node only**:
   ```
   python cassandra/create_cassandra_tables.py
   ```

---



## **Additional Notes**

1. **Ensure Synchronization**:
   - The `.env` files on both nodes must be consistent except for node-specific variables like IP addresses.

2. **Verify Container Health**:
   - Check the status of all containers:
     ```
     docker ps
     ```

3. **Logs and Debugging**:
   - Use the following command to view logs for a container:
     ```
     docker logs <container-name>
     ```

