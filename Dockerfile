FROM alpine:3.22

RUN apk add --no-cache bash restic docker-cli jq rsync tzdata ca-certificates

# Default schedule timezone; override with the TZ environment variable.
ENV TZ=Europe/Brussels

COPY dvb /usr/local/bin/dvb
RUN chmod +x /usr/local/bin/dvb

VOLUME /staging

# Healthy once the restore-if-needed pass has finished, so dependent
# services (depends_on: condition: service_healthy) wait for recovery.
HEALTHCHECK --interval=5s --timeout=3s --start-period=30m --retries=3 \
  CMD test -f /tmp/dvb-ready

ENTRYPOINT ["/usr/local/bin/dvb"]
CMD ["start"]
