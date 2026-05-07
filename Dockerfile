FROM python:3.14-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    udev \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r sms && useradd -r -g sms -G dialout sms

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY sms_server/ sms_server/

USER sms

ENTRYPOINT ["python", "-m", "sms_server"]
