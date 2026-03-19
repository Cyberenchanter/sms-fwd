#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/sms-fwd"
SERVICE_NAME="sms-fwd-server"
REPO_URL="https://github.com/Cyberenchanter/sms-fwd.git"
ACME_HOME="/root/.acme.sh"
CERT_DIR="${INSTALL_DIR}/certs"

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
fi

# --- Resolve source directory ---
resolve_source_dir() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Check if main.go exists alongside this script (already cloned)
    if [[ -f "${SCRIPT_DIR}/main.go" ]]; then
        SOURCE_DIR="$SCRIPT_DIR"
        ok "Source found in ${SOURCE_DIR}"
        return
    fi

    # Check current working directory
    if [[ -f "$(pwd)/main.go" ]]; then
        SOURCE_DIR="$(pwd)"
        ok "Source found in ${SOURCE_DIR}"
        return
    fi

    # Fall back to cloning
    info "Source not found locally, cloning repository..."
    CLONE_DIR="/tmp/sms-fwd-build"
    rm -rf "$CLONE_DIR"
    git clone "$REPO_URL" "$CLONE_DIR"
    SOURCE_DIR="${CLONE_DIR}/server"

    if [[ ! -f "${SOURCE_DIR}/main.go" ]]; then
        err "main.go not found after cloning. Repository structure may have changed."
    fi
    ok "Source cloned to ${SOURCE_DIR}"
}

# --- Detect package manager ---
detect_pkg_manager() {
    if command -v apt &>/dev/null; then
        echo "apt"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# --- Install Go ---
install_go() {
    if command -v go &>/dev/null; then
        ok "Go is already installed: $(go version)"
        return
    fi

    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    info "Installing Go via ${pkg_manager}..."
    case "$pkg_manager" in
        apt)
            apt update -y
            apt install -y golang-go git curl socat
            ;;
        pacman)
            pacman -Sy --noconfirm go git curl socat
            ;;
        *)
            err "Unsupported package manager. Install Go manually and re-run this script."
            ;;
    esac

    if ! command -v go &>/dev/null; then
        err "Go installation failed"
    fi
    ok "Go installed: $(go version)"
}

# --- Install acme.sh ---
install_acme() {
    if [[ -f "${ACME_HOME}/acme.sh" ]]; then
        ok "acme.sh is already installed"
        return
    fi

    info "Installing acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="${CFG_ACME_EMAIL}"

    if [[ ! -f "${ACME_HOME}/acme.sh" ]]; then
        err "acme.sh installation failed"
    fi
    ok "acme.sh installed"
}

# --- Issue TLS certificate ---
issue_certificate() {
    local domain="$1"

    info "Issuing TLS certificate for ${domain}..."
    info "This will use standalone mode on port 80 — make sure port 80 is open and not in use."

    mkdir -p "$CERT_DIR"

    "${ACME_HOME}/acme.sh" --issue \
        --standalone \
        -d "$domain" \
        --keylength ec-256 \
        --force \
        || err "Certificate issuance failed. Ensure DNS for ${domain} points to this server and port 80 is reachable."

    info "Installing certificate to ${CERT_DIR}..."
    "${ACME_HOME}/acme.sh" --install-cert \
        -d "$domain" \
        --ecc \
        --key-file       "${CERT_DIR}/key.pem" \
        --fullchain-file "${CERT_DIR}/cert.pem" \
        --reloadcmd      "systemctl restart ${SERVICE_NAME} 2>/dev/null || true"

    chmod 600 "${CERT_DIR}/key.pem"
    chmod 644 "${CERT_DIR}/cert.pem"

    CFG_TLS_CERT="${CERT_DIR}/cert.pem"
    CFG_TLS_KEY="${CERT_DIR}/key.pem"

    ok "Certificate issued and installed for ${domain}"
    ok "Auto-renewal is handled by acme.sh cron job"
}

# --- Build ---
build_server() {
    info "Building server from ${SOURCE_DIR}..."
    cd "$SOURCE_DIR"
    go build -o sms-fwd-server .
    ok "Build successful"
}

# --- Prompt for config ---
prompt_config() {
    echo ""
    echo -e "${CYAN}=== Server Configuration ===${NC}"
    echo ""

    read -rp "Telegram Bot Token (required): " CFG_BOT_TOKEN
    [[ -z "$CFG_BOT_TOKEN" ]] && err "Bot token is required"

    read -rp "Telegram Chat ID (required): " CFG_CHAT_ID
    [[ -z "$CFG_CHAT_ID" ]] && err "Chat ID is required"

    read -rp "Auth Bearer Token (required): " CFG_AUTH_TOKEN
    [[ -z "$CFG_AUTH_TOKEN" ]] && err "Auth token is required"

    read -rp "Listen Address [:10086]: " CFG_LISTEN_ADDR
    CFG_LISTEN_ADDR="${CFG_LISTEN_ADDR:-:10086}"

    read -rp "API Path [/forward]: " CFG_API_PATH
    CFG_API_PATH="${CFG_API_PATH:-/forward}"

    # --- TLS / Domain ---
    echo ""
    echo -e "${CYAN}=== TLS Configuration ===${NC}"
    read -rp "Domain name for TLS (leave empty to disable TLS): " CFG_DOMAIN
    CFG_DOMAIN="${CFG_DOMAIN:-}"

    CFG_TLS_CERT=""
    CFG_TLS_KEY=""
    CFG_ACME_EMAIL=""

    if [[ -n "$CFG_DOMAIN" ]]; then
        read -rp "Email for Let's Encrypt registration (required): " CFG_ACME_EMAIL
        [[ -z "$CFG_ACME_EMAIL" ]] && err "Email is required for certificate registration"
    fi

    # --- Summary ---
    echo ""
    echo -e "${CYAN}=== Configuration Summary ===${NC}"
    echo "  Bot Token:    ${CFG_BOT_TOKEN:0:10}..."
    echo "  Chat ID:      $CFG_CHAT_ID"
    echo "  Auth Token:   ${CFG_AUTH_TOKEN:0:6}..."
    echo "  Listen:       $CFG_LISTEN_ADDR"
    echo "  API Path:     $CFG_API_PATH"
    if [[ -n "$CFG_DOMAIN" ]]; then
        echo "  Domain:       $CFG_DOMAIN"
        echo "  ACME Email:   $CFG_ACME_EMAIL"
        echo "  TLS:          auto via acme.sh (Let's Encrypt)"
    else
        echo "  TLS:          disabled"
    fi
    echo ""

    read -rp "Proceed with installation? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        err "Installation cancelled"
    fi
}

# --- Setup TLS if domain provided ---
setup_tls() {
    if [[ -z "$CFG_DOMAIN" ]]; then
        warn "No domain specified — TLS disabled. Running in plain HTTP mode."
        return
    fi

    install_acme
    issue_certificate "$CFG_DOMAIN"
}

# --- Install files ---
install_files() {
    info "Installing to ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"

    cp "$SOURCE_DIR/sms-fwd-server" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/sms-fwd-server"

    # Generate start.sh from template
    if [[ ! -f "${SOURCE_DIR}/start.sh.example" ]]; then
        err "start.sh.example not found in ${SOURCE_DIR}"
    fi

    sed \
        -e "s|^export TELEGRAM_BOT_TOKEN=.*|export TELEGRAM_BOT_TOKEN=\"${CFG_BOT_TOKEN}\"|" \
        -e "s|^export TELEGRAM_CHAT_ID=.*|export TELEGRAM_CHAT_ID=\"${CFG_CHAT_ID}\"|" \
        -e "s|^export AUTH_TOKEN=.*|export AUTH_TOKEN=\"${CFG_AUTH_TOKEN}\"|" \
        -e "s|^export LISTEN_ADDR=.*|export LISTEN_ADDR=\"${CFG_LISTEN_ADDR}\"|" \
        -e "s|^export API_PATH=.*|export API_PATH=\"${CFG_API_PATH}\"|" \
        -e "s|^export TLS_CERT_FILE=.*|export TLS_CERT_FILE=\"${CFG_TLS_CERT}\"|" \
        -e "s|^export TLS_KEY_FILE=.*|export TLS_KEY_FILE=\"${CFG_TLS_KEY}\"|" \
        -e "s|^exec .*|exec ${INSTALL_DIR}/sms-fwd-server|" \
        "$SOURCE_DIR/start.sh.example" > "$INSTALL_DIR/start.sh"

    chmod 600 "$INSTALL_DIR/start.sh"      # protect secrets
    chmod +x "$INSTALL_DIR/start.sh"

    ok "Files installed"
}

# --- Install systemd service ---
install_service() {
    info "Installing systemd service..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SMS Forward Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/start.sh
Restart=always
RestartSec=5

WorkingDirectory=${INSTALL_DIR}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Service is running"
    else
        warn "Service may not have started correctly. Check: journalctl -u ${SERVICE_NAME} -f"
    fi
}

# --- Cleanup ---
cleanup() {
    # Only clean up if we cloned to a temp directory
    if [[ -n "${CLONE_DIR:-}" && -d "${CLONE_DIR:-}" ]]; then
        info "Cleaning up build directory..."
        rm -rf "$CLONE_DIR"
        ok "Cleanup done"
    fi
}

# --- Summary ---
print_summary() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  SMS Forward Proxy installed successfully  ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "  Install dir:  $INSTALL_DIR"
    echo "  Service:      $SERVICE_NAME"
    if [[ -n "$CFG_DOMAIN" ]]; then
        echo "  Domain:       $CFG_DOMAIN"
        echo "  TLS Cert:     ${CERT_DIR}/cert.pem"
        echo "  TLS Key:      ${CERT_DIR}/key.pem"
        echo "  Auto-renew:   managed by acme.sh cron"
    fi
    echo ""
    echo "  Useful commands:"
    echo "    sudo systemctl status $SERVICE_NAME"
    echo "    sudo systemctl restart $SERVICE_NAME"
    echo "    sudo systemctl stop $SERVICE_NAME"
    echo "    sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    echo "  Edit config:"
    echo "    sudo nano $INSTALL_DIR/start.sh"
    echo "    sudo systemctl restart $SERVICE_NAME"
    echo ""
}

# --- Main ---
main() {
    echo ""
    echo -e "${CYAN}=== SMS Forward Proxy Server Setup ===${NC}"
    echo ""

    resolve_source_dir
    install_go
    prompt_config
    build_server
    setup_tls
    install_files
    install_service
    cleanup
    print_summary
}

main