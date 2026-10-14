FROM debian:bookworm-slim
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends postfix python3 python3-prometheus-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home loadtest \
    && ln -s /usr/lib/postfix/sbin/smtp-source /usr/local/bin/smtp-source \
    && ln -s /usr/lib/postfix/sbin/smtp-sink /usr/local/bin/smtp-sink
COPY harness.py /opt/loadtest/harness.py
USER 10001:10001
EXPOSE 2525 9090
ENTRYPOINT ["python3", "-u", "/opt/loadtest/harness.py"]