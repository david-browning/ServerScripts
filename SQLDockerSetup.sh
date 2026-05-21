#!/usr/bin/env bash

set -euo pipefail

# SQL Server Docker setup script
# Assumes Docker and Docker Compose v2 are already installed.

readonly APP_DIR="/opt/mssql-dev"
readonly ENV_FILE="${APP_DIR}/.env"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
readonly CONTAINER_NAME="sql2025-dev"
readonly DEFAULT_IMAGE="mcr.microsoft.com/mssql/server:2025-latest"
readonly DEFAULT_DATABASE_NAME="WebsiteDev"
readonly SQL_PORT="1433"

echo "SQL Server Docker setup"
echo "-----------------------"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or is not in PATH."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose v2 is not available."
    echo "Expected: docker compose version"
    exit 1
fi

echo "Creating app directory: ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown "${USER}:${USER}" "${APP_DIR}"

echo
echo "Enter a strong SQL Server sa password."
echo "SQL Server requires a sufficiently complex password."
echo "Use something long with upper/lowercase letters, numbers, and symbols."
echo

while true; do
    read -rsp "SA password: " SA_PASSWORD
    echo
    read -rsp "Confirm SA password: " SA_PASSWORD_CONFIRM
    echo

    if [[ "${SA_PASSWORD}" != "${SA_PASSWORD_CONFIRM}" ]]; then
        echo "Passwords do not match. Try again."
        echo
        continue
    fi

    # if [[ ${#SA_PASSWORD} -lt 12 ]]; then
    #     echo "Password is too short. Use at least 12 characters."
    #     echo
    #     continue
    # fi

    break
done

echo "Writing ${ENV_FILE}"
cat > "${ENV_FILE}" <<EOF
SA_PASSWORD=${SA_PASSWORD}
EOF

chmod 600 "${ENV_FILE}"

if [[ -f "${COMPOSE_FILE}" ]]; then
    echo
    echo "Compose file already exists:"
    echo "  ${COMPOSE_FILE}"
    read -rp "Overwrite it with a standard SQL Server 2025 Developer compose file? [y/N]: " OVERWRITE_COMPOSE

    if [[ "${OVERWRITE_COMPOSE}" =~ ^[Yy]$ ]]; then
        WRITE_COMPOSE="true"
    else
        WRITE_COMPOSE="false"
    fi
else
    WRITE_COMPOSE="true"
fi

if [[ "${WRITE_COMPOSE}" == "true" ]]; then
    echo "Writing ${COMPOSE_FILE}"

    cat > "${COMPOSE_FILE}" <<EOF
services:
  sqlserver:
    image: ${DEFAULT_IMAGE}
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_PID: "Developer"
      MSSQL_SA_PASSWORD: "\${SA_PASSWORD}"
    ports:
      - "${SQL_PORT}:1433"
    volumes:
      - sqlserver_data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \\"\$\${MSSQL_SA_PASSWORD}\\" -C -Q \\"SELECT 1\\" || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 20

volumes:
  sqlserver_data:
EOF
else
    echo "Keeping existing compose file."
fi

echo
echo "Firewall setup"
echo "--------------"

if command -v ufw >/dev/null 2>&1; then
    echo "ufw detected."

    read -rp "Open TCP port ${SQL_PORT} with ufw? [Y/n]: " OPEN_FIREWALL
    OPEN_FIREWALL="${OPEN_FIREWALL:-Y}"

    if [[ "${OPEN_FIREWALL}" =~ ^[Yy]$ ]]; then
        echo "Opening TCP port ${SQL_PORT}."
        sudo ufw allow "${SQL_PORT}/tcp"

        echo "Reloading ufw."
        sudo ufw reload || true

        echo
        echo "Current ufw status:"
        sudo ufw status verbose || true
    else
        echo "Skipping ufw rule."
    fi
else
    echo "ufw not found. Skipping firewall rule."
    echo "If you use another firewall, allow inbound TCP ${SQL_PORT} from your LAN/VPN only."
fi

if docker ps >/dev/null 2>&1; then
    DOCKER="docker"
elif sudo docker ps >/dev/null 2>&1; then
    DOCKER="sudo docker"
else
    echo "ERROR: Docker is not available to this user, even with sudo."
    exit 1
fi

echo
echo "Pulling SQL Server container image..."
${DOCKER} compose --project-directory "${APP_DIR}" pull


sudo systemctl enable docker
sudo systemctl enable containerd

echo
echo "Setup complete."
echo
echo "Useful commands"
echo "---------------"
echo
echo "Start SQL Server:"
echo "  cd ${APP_DIR}"
echo "  docker compose up -d"
echo
echo "Check container status:"
echo "  docker ps"
echo
echo "Follow SQL Server logs:"
echo "  docker logs -f ${CONTAINER_NAME}"
echo
echo "Stop SQL Server:"
echo "  cd ${APP_DIR}"
echo "  docker compose down"
echo
echo "Restart SQL Server:"
echo "  cd ${APP_DIR}"
echo "  docker compose restart"
echo
echo "Create a dev database after SQL Server is running:"
echo "  cd ${APP_DIR}"
echo "  source .env"
echo "  docker exec -it ${CONTAINER_NAME} /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"\$SA_PASSWORD\" -C -Q \"CREATE DATABASE ${DEFAULT_DATABASE_NAME};\""
echo
echo "Connect from SSMS:"
echo "  Server name: <VM_STATIC_IP>,${SQL_PORT}"
echo "  Authentication: SQL Server Authentication"
echo "  Login: sa"
echo "  Password: the password you entered"
echo "  Trust Server Certificate: checked"
echo
echo "Important:"
echo "  Do not expose port ${SQL_PORT} directly to the public internet."
echo "  Prefer LAN/VPN-only access."
