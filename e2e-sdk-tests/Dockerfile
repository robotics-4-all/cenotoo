FROM python:3.11-slim

WORKDIR /app

COPY . /app

# git is required for the pinned SDK install (git+https in requirements.txt).
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt

# In-cluster default; override with -e CENOTOO_BASE_URL=... for external API.
ENV CENOTOO_BASE_URL=http://cenotoo-api:8000
ENV E2E_PREFIX=e2e
ENV E2E_TIMEOUT_S=300
ENV E2E_INTERVAL_S=2

CMD ["pytest", "-m", "e2e", "-v"]
