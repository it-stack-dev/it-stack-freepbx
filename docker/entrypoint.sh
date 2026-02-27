#!/bin/bash
# entrypoint.sh — IT-Stack freepbx container entrypoint
set -euo pipefail

echo "Starting IT-Stack FREEPBX (Module 10)..."

# Source any environment overrides
if [ -f /opt/it-stack/freepbx/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/freepbx/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
