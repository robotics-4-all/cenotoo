FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mqtt_auth.py .

EXPOSE 8080

CMD ["python", "mqtt_auth.py"]
