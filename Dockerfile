# Dockerfile — IT-Stack FREEPBX wrapper
# Module 10 | Category: communications | Phase: 3
# Base image: tiredofit/freepbx:16

FROM tiredofit/freepbx:16

# Labels
LABEL org.opencontainers.image.title="it-stack-freepbx" \
      org.opencontainers.image.description="FreePBX/Asterisk VoIP PBX" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-freepbx"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/freepbx/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
