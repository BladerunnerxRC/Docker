# Script body below only used to create the script entity in the Borg UI that prepares app-consistent data for backup.
# The actual content of the script is in borg-prep-matomo.sh, which is the one that gets executed by the Borg backup process.
# This script is essentially a placeholder that triggers the Matomo database dump and web-root archive before the
# Borg backup runs, so the analytics data and the matching Matomo code/config are captured together.
#
# Name: matomo-prep-dbdump
# Description: Pre-backup MariaDB dump + web-root archive for the Matomo analytics stack
# Run-on: Always - Reguardless of result
# Time-out: 600 seconds (10 minutes) — Matomo's log tables grow with traffic
#
# Borg must also include /var/backups/borg-matomo/latest in its backup paths,
# or the snapshot is produced and never archived.
#
# !! Set MATOMO_DOCKER_HOST below to the Docker host that runs the Matomo stack. !!
#
# Script Content:

#!/bin/bash
set -Eeuo pipefail

MATOMO_DOCKER_HOST="CHANGE_ME_DOCKER_HOST_IP"

echo "Starting Matomo pre-backup snapshot..."

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  "root@${MATOMO_DOCKER_HOST}" \
  /usr/local/sbin/borg-prep-matomo.sh

echo "Matomo pre-backup snapshot completed."
