#!/bin/sh
# Minimal test hook - just log that we were called
echo "$(date -Iseconds) HOOK CALLED: $*" >> /var/log/shairport-sync/test-hook.log

