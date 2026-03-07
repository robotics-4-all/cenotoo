# Use an official Python runtime as a parent image
FROM python:3.8-slim

# Set the working directory in the container
WORKDIR /app

# Copy the current directory contents into the container at /app
COPY . /app

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Define environment variables
ENV KAFKA_BOOTSTRAP_SERVERS=localhost:9092
ENV CASSANDRA_CONTACT_POINTS=localhost
ENV CASSANDRA_PORT=9042
ENV COLLECTION_NAME=your_topic_name
ENV PROJECT_NAME=your_keyspace_name
ENV ORGANIZATION_NAME=your_table_name

# Run consume_and_store.py when the container launches
CMD ["python", "consumer.py"]
