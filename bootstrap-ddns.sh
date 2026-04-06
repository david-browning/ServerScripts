#!/usr/bin/env bash
set -euo pipefail

########################################
# ========== USER VARIABLES ===========
########################################

POWERSHELL_VERSION="7.5.5"
DDNS_DIR="/opt/ddns"

DOMAIN="MYWEBSITE.com"
RECORD="SUBDOMAIN"

CRON_SCHEDULE="*/10 * * * *"
TTL="600"

GODADDY_API_KEY="REPLACE_ME"
GODADDY_API_SECRET="REPLACE_ME"

########################################
# ===== DERIVED / DO NOT EDIT =========
########################################

FQDN="${RECORD}.${DOMAIN}"
CONFIG_NAME="ddns-${FQDN}.psd1"
SCRIPT_NAME="update-${FQDN}.ps1"
CONFIG_PATH="${DDNS_DIR}/${CONFIG_NAME}"
SCRIPT_PATH="${DDNS_DIR}/${SCRIPT_NAME}"
LOG_FILE="/var/log/${FQDN}-ddns.log"
LOGROTATE_FILE="/etc/logrotate.d/${FQDN}-ddns"

POWERSHELL_DEB="powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb"
POWERSHELL_URL="https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${POWERSHELL_DEB}"

########################################
# ========== PRECHECKS ================
########################################

if [[ "${GODADDY_API_KEY}" == "REPLACE_ME" || "${GODADDY_API_SECRET}" == "REPLACE_ME" ]]; then
    echo "GoDaddy API key/secret still set to REPLACE_ME. Update the variables at the top first."
    exit 1
fi

########################################
# ======== INSTALL DEPENDENCIES =======
########################################

echo "Installing PowerShell ${POWERSHELL_VERSION}..."

cd /tmp
rm -f "${POWERSHELL_DEB}"
wget -q "${POWERSHELL_URL}"

dpkg -i "${POWERSHELL_DEB}" || true
apt-get update -y
apt-get install -f -y

########################################
# ========== CREATE FILES =============
########################################

echo "Creating DDNS directory and files..."

mkdir -p "${DDNS_DIR}"
chmod 700 "${DDNS_DIR}"

cat > "${CONFIG_PATH}" <<EOF
@{
    Domain    = '${DOMAIN}'
    Record    = '${RECORD}'
    ApiKey    = '${GODADDY_API_KEY}'
    ApiSecret = '${GODADDY_API_SECRET}'
    Ttl       = ${TTL}
}
EOF

chmod 600 "${CONFIG_PATH}"

cat > "${SCRIPT_PATH}" <<EOF
\$ErrorActionPreference = 'Stop'

function Get-BaseUri([string]\$Domain, [string]\$Record) {
    return "https://api.godaddy.com/v1/domains/\$Domain/records/A/\$Record"
}

function Get-AuthHeaders([string]\$ApiKey, [string]\$ApiSecret) {
    return @{
        Authorization = "sso-key \$ApiKey\`:\$ApiSecret"
        'Content-Type' = 'application/json'
    }
}

function Get-PublicIp {
    return (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
}

function Get-GoDaddyRecords(
    [string]\$Domain,
    [string]\$Record,
    [string]\$ApiKey,
    [string]\$ApiSecret
) {
    \$uri = Get-BaseUri -Domain \$Domain -Record \$Record
    \$headers = Get-AuthHeaders -ApiKey \$ApiKey -ApiSecret \$ApiSecret

    return Invoke-RestMethod -Method Get -Uri \$uri -Headers \$headers
}

function Set-GoDaddyRecords(
    [string]\$Domain,
    [string]\$Record,
    [string]\$ApiKey,
    [string]\$ApiSecret,
    [string]\$IpAddress,
    [int]\$Ttl
) {
    \$uri = Get-BaseUri -Domain \$Domain -Record \$Record
    \$headers = Get-AuthHeaders -ApiKey \$ApiKey -ApiSecret \$ApiSecret

    \$body = ConvertTo-Json -InputObject @(
        @{
            data = \$IpAddress
            ttl  = \$Ttl
        }
    ) -Compress

    Invoke-RestMethod -Method Put -Uri \$uri -Headers \$headers -ContentType 'application/json' -Body \$body | Out-Null
}

try {
    \$config = Import-PowerShellDataFile '${CONFIG_PATH}'

    \$currentIp = Get-PublicIp
    if ([string]::IsNullOrWhiteSpace(\$currentIp)) {
        throw 'Could not determine public IP.'
    }

    \$vpnResult = Get-GoDaddyRecords -Domain \$config.Domain -Record \$config.Record -ApiKey \$config.ApiKey -ApiSecret \$config.ApiSecret
    if (\$null -eq \$vpnResult) {
        throw 'GoDaddy GET returned null.'
    }

    if (\$vpnResult -isnot [array]) {
        \$vpnResult = @(\$vpnResult)
    }

    if (\$vpnResult.Count -ne 1) {
        throw "Expected exactly 1 A record for \$([string]\$config.Record).\$([string]\$config.Domain), got \$([string]\$vpnResult.Count)."
    }

    \$dnsIp = \$vpnResult[0].data.Trim()
    if ([string]::IsNullOrWhiteSpace(\$dnsIp)) {
        throw 'DNS record data field was empty.'
    }

    Write-Output "\$(Get-Date -Format o) - Current IP: \$currentIp | DNS IP: \$dnsIp"

    if (\$dnsIp -eq \$currentIp) {
        Write-Output "\$(Get-Date -Format o) - No update needed."
        exit 0
    }

    Write-Output "\$(Get-Date -Format o) - Updating ${FQDN} from \$dnsIp to \$currentIp"

    Set-GoDaddyRecords `
        -Domain \$config.Domain `
        -Record \$config.Record `
        -ApiKey \$config.ApiKey `
        -ApiSecret \$config.ApiSecret `
        -IpAddress \$currentIp `
        -Ttl \$config.Ttl

    Write-Output "\$(Get-Date -Format o) - Update successful."
}
catch {
    Write-Error "\$(Get-Date -Format o) - ERROR: \$_"
    exit 1
}
EOF

chmod 700 "${SCRIPT_PATH}"

########################################
# ========== SETUP CRON ===============
########################################

echo "Installing cron entry..."

CRON_LINE="${CRON_SCHEDULE} /usr/bin/pwsh -File ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"

TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -F -v "${SCRIPT_PATH}" > "${TMP_CRON}" || true
echo "${CRON_LINE}" >> "${TMP_CRON}"
crontab "${TMP_CRON}"
rm -f "${TMP_CRON}"

########################################
# ======== SETUP LOGROTATE ============
########################################

echo "Creating logrotate config..."

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

########################################
# ========== FINAL OUTPUT =============
########################################

echo
echo "Setup complete."
echo
echo "FQDN:           ${FQDN}"
echo "Config file:    ${CONFIG_PATH}"
echo "Script file:    ${SCRIPT_PATH}"
echo "Log file:       ${LOG_FILE}"
echo "Cron schedule:  ${CRON_SCHEDULE}"
echo
echo "Manual test:"
echo "  pwsh -File '${SCRIPT_PATH}'"
echo
echo "Verify DNS:"
echo "  nslookup '${FQDN}'"
echo
echo "Watch logs:"
echo "  tail -f '${LOG_FILE}'"
