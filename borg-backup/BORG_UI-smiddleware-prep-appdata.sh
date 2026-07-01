# Script body below only used to create the script entity in the Borg UI that prepares app-consistent data for backup. 
# The actual content of the script is in borg-prep-appdata-smiddleware.sh, which is the one that gets executed by the Borg backup process.
# This script is essentially a placeholder that can be used to trigger the preparation of app-consistent data before the Borg backup runs,
# ensuring that all necessary information and data from the applications are captured in a consistent state for backup.

# NAme: smiddleware-prep-appdata
# Description: Pre-backup app-data snapshot for smiddleware Docker services
# Run-on: Always - Reguardless of result
# Time-out: 300 seconds (5 minutes)
# Script Content:

#!/bin/bash
set -Eeuo pipefail

echo "Starting smiddleware pre-backup app-data prep..."

ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  root@192.168.200.52 \
  /usr/local/sbin/borg-prep-appdata-smiddleware.sh

echo "smiddleware pre-backup app-data prep completed."