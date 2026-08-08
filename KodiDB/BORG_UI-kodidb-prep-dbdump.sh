# Script body below only used to create the script entity in the Borg UI that prepares app-consistent data for backup.
# The actual content of the script is in borg-prep-kodidb.sh, which is the one that gets executed by the Borg backup process.
# This script is essentially a placeholder that can be used to trigger the Kodi database dump before the Borg backup runs,
# ensuring the shared Kodi library (watched status, resume points, play counts) is captured in a consistent state.
#
# Name: kodidb-prep-dbdump
# Description: Pre-backup MariaDB dump for the shared Kodi library backend
# Run-on: Always - Reguardless of result
# Time-out: 300 seconds (5 minutes)
#
# Borg must also include /var/backups/borg-kodidb/latest in its backup paths,
# or the dump is produced and never archived.
#
# Script Content:

#!/bin/bash
set -Eeuo pipefail

echo "Starting KodiDB pre-backup database dump..."

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  root@192.168.1.20 \
  /usr/local/sbin/borg-prep-kodidb.sh

echo "KodiDB pre-backup database dump completed."
