#!/usr/bin/env bash
set -euo pipefail

########################################
# ========== USER VARIABLES ===========
########################################

SOURCE_POOL="data_pool"
BACKUP_POOL="backup_pool"

RETENTION_COUNT="60"
# Run at 2 AM each day
CRON_SCHEDULE="0 2 * * *"

INSTALL_DIR="/opt/infra/zfs"
SCRIPT_NAME="replicate-${SOURCE_POOL}-to-${BACKUP_POOL}.sh"
README_NAME="README.md"

LOG_FILE="/var/log/zfs-${SOURCE_POOL}-to-${BACKUP_POOL}.log"
LOGROTATE_FILE="/etc/logrotate.d/zfs-${SOURCE_POOL}-to-${BACKUP_POOL}"

########################################
# ===== DERIVED / DO NOT EDIT =========
########################################

SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
README_PATH="${INSTALL_DIR}/${README_NAME}"

########################################
# ============ PRECHECKS ==============
########################################

if ! command -v zfs >/dev/null 2>&1; then
    echo "zfs command not found. Install/configure ZFS first."
    exit 1
fi

if ! zfs list "${SOURCE_POOL}" >/dev/null 2>&1; then
    echo "Source pool/dataset '${SOURCE_POOL}' does not exist."
    exit 1
fi

if ! zfs list "${BACKUP_POOL}" >/dev/null 2>&1; then
    echo "Backup pool/dataset '${BACKUP_POOL}' does not exist."
    exit 1
fi

########################################
# ========= INSTALL STRUCTURE =========
########################################

echo "Creating install directory..."
mkdir -p "${INSTALL_DIR}"
chmod 700 "${INSTALL_DIR}"

########################################
# ======= WRITE REPLICATION SCRIPT ====
########################################

echo "Writing replication script to ${SCRIPT_PATH} ..."

cat > "${SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SOURCE_POOL="${SOURCE_POOL}"
BACKUP_POOL="${BACKUP_POOL}"
RETENTION_COUNT="${RETENTION_COUNT}"

TIMESTAMP=\$(date +%Y%m%d-%H%M)
CURRENT_SNAPSHOT="\${SOURCE_POOL}@auto-\${TIMESTAMP}"

log() {
    echo "\$(date --iso-8601=seconds) - \$*"
}

log "Starting ZFS replication job"
log "Source pool: \${SOURCE_POOL}"
log "Backup pool: \${BACKUP_POOL}"

# Create a new recursive snapshot on the source.
log "Creating recursive snapshot: \${CURRENT_SNAPSHOT}"
zfs snapshot -r "\${CURRENT_SNAPSHOT}"

# Find the previous top-level auto snapshot on the source, excluding the one we just created.
PREVIOUS_SNAPSHOT=\$(
    zfs list -t snapshot -H -o name -S creation |
    grep "^\\\${SOURCE_POOL}@auto-" |
    grep -v "^\\\${CURRENT_SNAPSHOT}\$" |
    head -n 1 || true
)

if [[ -z "\${PREVIOUS_SNAPSHOT}" ]]; then
    log "No previous auto snapshot found. Performing full recursive send."
    zfs send -R "\${CURRENT_SNAPSHOT}" | zfs receive -Fdu "\${BACKUP_POOL}"
else
    log "Previous auto snapshot found: \${PREVIOUS_SNAPSHOT}"
    log "Performing incremental recursive send from \${PREVIOUS_SNAPSHOT} to \${CURRENT_SNAPSHOT}"
    zfs send -R -I "\${PREVIOUS_SNAPSHOT}" "\${CURRENT_SNAPSHOT}" | zfs receive -Fdu "\${BACKUP_POOL}"
fi

# Retention on source: keep newest RETENTION_COUNT top-level auto snapshots.
OLD_SOURCE_SNAPSHOTS=\$(
    zfs list -t snapshot -H -o name -S creation |
    grep "^\\\${SOURCE_POOL}@auto-" |
    tail -n +\$((RETENTION_COUNT + 1)) || true
)

if [[ -n "\${OLD_SOURCE_SNAPSHOTS}" ]]; then
    log "Applying source snapshot retention"
    while IFS= read -r SNAP; do
        [[ -z "\${SNAP}" ]] && continue
        log "Destroying old source snapshot recursively: \${SNAP}"
        zfs destroy -r "\${SNAP}"
    done <<< "\${OLD_SOURCE_SNAPSHOTS}"
else
    log "No old source snapshots to destroy"
fi

# Retention on backup: keep newest RETENTION_COUNT top-level replicated auto snapshots.
# With 'zfs receive -d -u BACKUP_POOL', a source pool named 'data_pool' lands as:
#   BACKUP_POOL/data_pool
OLD_BACKUP_SNAPSHOTS=\$(
    zfs list -t snapshot -H -o name -S creation |
    grep "^\\\${BACKUP_POOL}/\\\${SOURCE_POOL}@auto-" |
    tail -n +\$((RETENTION_COUNT + 1)) || true
)

if [[ -n "\${OLD_BACKUP_SNAPSHOTS}" ]]; then
    log "Applying backup snapshot retention"
    while IFS= read -r SNAP; do
        [[ -z "\${SNAP}" ]] && continue
        log "Destroying old backup snapshot recursively: \${SNAP}"
        zfs destroy -r "\${SNAP}"
    done <<< "\${OLD_BACKUP_SNAPSHOTS}"
else
    log "No old backup snapshots to destroy"
fi

log "ZFS replication job completed successfully"
EOF

chmod 700 "${SCRIPT_PATH}"

########################################
# ============ WRITE README ===========
########################################

echo "Writing README to ${README_PATH} ..."

cat > "${README_PATH}" <<EOF
ZFS Replication Runbook
=======================

Purpose
-------
This directory contains the authoritative bootstrap-installed ZFS replication script.

Source
------
${SOURCE_POOL}

Target
------
${BACKUP_POOL}

Installed Script
----------------
${SCRIPT_PATH}

Schedule
--------
${CRON_SCHEDULE}

Log File
--------
${LOG_FILE}

Log Rotation
------------
${LOGROTATE_FILE}

Retention
---------
Keeps the newest ${RETENTION_COUNT} top-level auto snapshots on:
- ${SOURCE_POOL}
- ${BACKUP_POOL}/${SOURCE_POOL}

Snapshot Naming
---------------
auto-YYYYMMDD-HHMM

Operational Notes
-----------------
- Creates a recursive snapshot on the source.
- If no prior auto snapshot exists, performs a full recursive send.
- Otherwise performs an incremental recursive send.
- Uses 'zfs receive -Fdu ${BACKUP_POOL}'.
- The replicated source lands under:
  ${BACKUP_POOL}/${SOURCE_POOL}

Useful Commands
---------------
Run manually:
  ${SCRIPT_PATH}

Watch log:
  tail -f ${LOG_FILE}

See pools/datasets:
  zfs list
  zpool status

See snapshots:
  zfs list -t snapshot

See cron:
  crontab -l

See logrotate config:
  cat ${LOGROTATE_FILE}
EOF

chmod 600 "${README_PATH}"

########################################
# ============ INSTALL CRON ===========
########################################

echo "Installing root cron entry..."

CRON_LINE="${CRON_SCHEDULE} ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"

TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -F -v "${SCRIPT_PATH}" > "${TMP_CRON}" || true
echo "${CRON_LINE}" >> "${TMP_CRON}"
crontab "${TMP_CRON}"
rm -f "${TMP_CRON}"

########################################
# ========= INSTALL LOGROTATE =========
########################################

echo "Writing logrotate config to ${LOGROTATE_FILE} ..."

cat > "${LOGROTATE_FILE}" <<EOF
${LOG_FILE} {
    size 1M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

chmod 644 "${LOGROTATE_FILE}"

########################################
# ============== OUTPUT ===============
########################################

echo
echo "Bootstrap complete."
echo
echo "Source pool:      ${SOURCE_POOL}"
echo "Backup pool:      ${BACKUP_POOL}"
echo "Replication script:${SCRIPT_PATH}"
echo "README:           ${README_PATH}"
echo "Log file:         ${LOG_FILE}"
echo "Cron schedule:    ${CRON_SCHEDULE}"
echo
echo "Next steps:"
echo "1. Review the generated script:"
echo "   cat ${SCRIPT_PATH}"
echo
echo "2. Run it manually once:"
echo "   ${SCRIPT_PATH}"
echo
echo "3. Verify replicated datasets:"
echo "   zfs list -r ${BACKUP_POOL}"
echo
echo "4. Verify snapshots:"
echo "   zfs list -t snapshot | grep '${SOURCE_POOL}@auto-'"
echo "   zfs list -t snapshot | grep '${BACKUP_POOL}/${SOURCE_POOL}@auto-'"
echo
echo "5. Watch logs:"
echo "   tail -f ${LOG_FILE}"
