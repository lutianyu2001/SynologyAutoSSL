#!/bin/bash

# path of this script
BASE_ROOT="$(cd "$(dirname "$0")" && pwd)"
# date time
DATE_TIME="$(date +%Y%m%d%H%M%S)"
# base crt path
CRT_BASE_PATH="/usr/syno/etc/certificate"
PKG_CRT_BASE_PATH="/usr/local/etc/certificate"
#CRT_BASE_PATH="/Users/carl/Downloads/certificate"
ACME_SH_ADDRESS="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
ACME_BIN_PATH="$(eval echo ~$(whoami))/.acme.sh"
TEMP_PATH="${BASE_ROOT}/temp_${DATE_TIME}"

# Color codes for better visibility
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function for logging
log() {
    local level=$1
    shift
    local timestamp=$(date "+[%a %b %d %I:%M:%S %p %Z %Y]")
    case $level in
        "INFO")  echo -e "${timestamp} ${GREEN}[INFO]${NC} $*" ;;
        "ERROR") echo -e "${timestamp} ${RED}[ERROR]${NC} $*" ;;
        "WARN")  echo -e "${timestamp} ${YELLOW}[WARN]${NC} $*" ;;
    esac
}

check_root_user() {
    if [ "$(id -u)" = "0" ]; then
        log "WARN" "Script is being run as root user. This is not recommended but will continue..."
        return 0
    fi
    return 1
}

check_sudo_nopasswd() {
    log "INFO" "Checking sudo password-less access configuration..."
    
    # Skip check if running as root
    if check_root_user; then
        return 0
    fi
    
    # Test sudo access without password using -n flag
    if ! sudo -n true 2>/dev/null; then
        log "ERROR" "Sudo requires password. Please configure sudo for password-less access first."
        log "ERROR" "You can configure it by:"
        log "ERROR" "1. Switch to root user: sudo -i"
        log "ERROR" "2. Edit sudoers: vim /etc/sudoers"
        log "ERROR" "3. Add the following two lines (replace <USER> with your username):"
        log "ERROR" "   # Allow password-less sudo for <USER>"
        log "ERROR" "   <USER> ALL=(ALL) NOPASSWD: ALL"
        return 1
    fi
    
    log "INFO" "Sudo password-less access is properly configured"
    return 0
}

check_certificate_path() {
    log "INFO" "Checking certificate path access..."
    if ! sudo test -r "${CRT_BASE_PATH}/_archive/DEFAULT"; then
        log "ERROR" "Cannot read default certificate path. " \
                    "Please check if certificate path exists and has proper permissions."
        return 1
    fi

    CRT_PATH_NAME="$(sudo cat "${CRT_BASE_PATH}/_archive/DEFAULT")"
    CRT_PATH="${CRT_BASE_PATH}/_archive/${CRT_PATH_NAME}"
    
    log "INFO" "Certificate path is accessible"
    return 0
}

check_config() {
    if [ ! -f "${BASE_ROOT}/config" ]; then
        log "ERROR" "Config file not found. Please check the \"config\" file."
        return 1
    fi
    
    source "${BASE_ROOT}/config"

    # Validate required config variables
    local required_vars=("ACCOUNT_EMAIL" "DOMAIN" "DNS" "DNS_SLEEP")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log "ERROR" "Missing required config variable: ${var}. Please check \"config\" file."
            return 1
        fi
    done
    
    return 0
}

check_requirements() {
    local required_commands=("curl" "tar" "python3")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            log "ERROR" "${cmd} is required but not installed. Please install it first."
            return 1
        fi
    done
    return 0
}

# Perform all required checks before proceeding
if ! check_sudo_nopasswd || ! check_config || ! check_certificate_path || ! check_requirements; then
    exit 1
fi

backupCrt() {
    log "INFO" "Creating backup of certificates..."
    BACKUP_PATH="${BASE_ROOT}/backup/${DATE_TIME}"
    if ! mkdir -p "${BACKUP_PATH}"; then
        log "ERROR" "Failed to create backup directory"
        return 1
    fi
    
    if ! sudo cp -r "${CRT_BASE_PATH}" "${BACKUP_PATH}"; then
        log "ERROR" "Failed to backup main certificates"
        return 1
    fi
    
    if ! sudo cp -r "${PKG_CRT_BASE_PATH}" "${BACKUP_PATH}/package_cert"; then
        log "ERROR" "Failed to backup package certificates"
        return 1
    fi
    
    echo "${BACKUP_PATH}" > "${BASE_ROOT}/backup/latest"
    sudo chmod -R 777 "${BACKUP_PATH}"
    log "INFO" "Backup completed successfully at ${BACKUP_PATH}"
    return 0
}

installAcme() {
    log "INFO" "Installing acme.sh..."
    if ! mkdir -p "${TEMP_PATH}"; then
        log "ERROR" "Failed to create temporary directory"
        return 1
    fi
    
    log "INFO" "Downloading acme.sh tool..."
    local SRC_TAR_PATH="${TEMP_PATH}/acme.sh.tar.gz"
    if ! curl -L -o "${SRC_TAR_PATH}" "${ACME_SH_ADDRESS}"; then
        log "ERROR" "Failed to download acme.sh"
        return 1
    fi
    
    local SRC_NAME="$(tar -tzf "${SRC_TAR_PATH}" | head -1 | cut -f1 -d"/")"
    tar -C "${TEMP_PATH}" -zxf "${SRC_TAR_PATH}"
    
    cd "${TEMP_PATH}/${SRC_NAME}" || {
        log "ERROR" "Failed to change to acme.sh directory"
        return 1
    }
    ./acme.sh --install --no-profile --nocron --email "${ACCOUNT_EMAIL}" || {
        log "ERROR" "Failed to install acme.sh"
        return 1
    }
    cd - >/dev/null 2>&1 || {
        log "ERROR" "Failed to change back to original directory"
        return 1
    }

    sudo chmod -R 777 "${ACME_BIN_PATH}"
    # source "${ACME_BIN_PATH}/acme.sh.env"
    rm -rf "${TEMP_PATH}"
    log "INFO" "acme.sh installed successfully"
    return 0
}

generateCrt() {
    log "INFO" "Generating certificates..."

    log "INFO" "Setting default CA to Let's Encrypt..."
    "${ACME_BIN_PATH}/acme.sh" --set-default-ca --server letsencrypt
    
    log "INFO" "Requesting certificate from Let's Encrypt..."
    "${ACME_BIN_PATH}/acme.sh" --force --log --issue --dns "${DNS}" --dnssleep "${DNS_SLEEP}" \
        -d "${DOMAIN}" -d "*.${DOMAIN}" --server letsencrypt
    
    log "INFO" "Installing certificate..."
    sudo --preserve-env "${ACME_BIN_PATH}/acme.sh" --force --log --installcert -d "${DOMAIN}" -d "*.${DOMAIN}" \
        --certpath "${CRT_PATH}/cert.pem" \
        --key-file "${CRT_PATH}/privkey.pem" \
        --fullchain-file "${CRT_PATH}/fullchain.pem"
    
    sudo chmod -R 777 "${ACME_BIN_PATH}"

    if sudo test -s "${CRT_PATH}/cert.pem"; then
        log "INFO" "Certificate generated successfully"
        return 0
    else
        log "ERROR" "Failed to generate certificate"
        cp "${ACME_BIN_PATH}/acme.sh.log" "${BASE_ROOT}/acme.sh.log"
        log "ERROR" "Please check the log file for more details: ${BASE_ROOT}/acme.sh.log"
        log "WARN" "Starting revert process..."
        revertCrt
        cleanUp
        exit 1
    fi
}

updateService() {
    log "INFO" "Updating certificate service..."
    if [ -z "${CRT_PATH_NAME}" ]; then
        log "ERROR" "Certificate path name is not set"
        return 1
    fi
    
    if ! sudo python3 "${BASE_ROOT}/crt_cp.py" "${CRT_PATH_NAME}"; then
        log "ERROR" "Failed to copy certificates"
        return 1
    fi
    
    log "INFO" "Certificate service updated successfully"
    return 0
}

reloadService() {
    log "INFO" "Reloading services..."
    
    log "INFO" "Regenerating certificate configuration..."
    if ! sudo /usr/syno/bin/synow3tool --gen-all; then
        log "ERROR" "Failed to regenerate certificate configuration"
        return 1
    fi
    
    log "INFO" "Reloading Nginx..."
    if ! sudo systemctl reload nginx; then
        log "ERROR" "Failed to reload Nginx"
        return 1
    fi
    
    log "INFO" "Restarting WebDAV service..."
    if ! sudo synopkg restart WebDAVServer; then
        log "ERROR" "Failed to restart WebDAV service"
        return 1
    fi
    
    log "INFO" "Services reloaded successfully"
    return 0
}

revertCrt() {
    local backup_id="$1"
    log "INFO" "Reverting to previous certificate backup..."
    
    BACKUP_PATH="${BASE_ROOT}/backup/${backup_id}"
    if [ -z "${backup_id}" ]; then
        if [ ! -f "${BASE_ROOT}/backup/latest" ]; then
            log "ERROR" "No backup history found"
            return 1
        fi
        BACKUP_PATH="$(cat "${BASE_ROOT}/backup/latest")"
    fi
    
    if [ ! -d "${BACKUP_PATH}" ]; then
        log "ERROR" "Backup path not found: ${BACKUP_PATH}"
        return 1
    fi
    
    log "INFO" "Restoring certificates from ${BACKUP_PATH}..."
    
    if ! sudo cp -rf "${BACKUP_PATH}/certificate/"* "${CRT_BASE_PATH}"; then
        log "ERROR" "Failed to restore main certificates"
        return 1
    fi
    
    if ! sudo cp -rf "${BACKUP_PATH}/package_cert/"* "${PKG_CRT_BASE_PATH}"; then
        log "ERROR" "Failed to restore package certificates"
        return 1
    fi
    
    if ! reloadService; then
        log "ERROR" "Failed to reload web services after reverting"
        return 1
    fi
    
    log "INFO" "Certificate restoration completed successfully"
    return 0
}

cleanUp() {
    log "INFO" "Cleaning up temporary files and installations..."
    
    if [ -d "${ACME_BIN_PATH}" ]; then
        log "INFO" "Uninstalling acme.sh..."
        "${ACME_BIN_PATH}/acme.sh" --uninstall
        
        log "INFO" "Removing acme.sh directory..."
        if ! rm -rf "${ACME_BIN_PATH}"; then
            log "WARN" "Failed to remove acme.sh directory: ${ACME_BIN_PATH}"
        fi
    fi
    
    if [ -d "/root/.acme.sh" ]; then
        log "INFO" "Removing acme.sh user directory..."
        if ! sudo rm -rf "/root/.acme.sh"; then
            log "WARN" "Failed to remove acme.sh user directory"
        fi
    fi
    
    log "INFO" "Cleanup completed"
    return 0
}

updateCrt() {
    log "INFO" "Starting certificate update process..."
    
    local steps=("backupCrt" "installAcme" "generateCrt" "updateService" "reloadService" "cleanUp")
    for step in "${steps[@]}"; do
        log "INFO" "Executing step: $step"
        if ! $step; then
            log "ERROR" "Failed at step: $step"
            exit 1
        fi
    done
    
    log "INFO" "Certificate update completed successfully"
}

# Show help message
show_help() {
    echo "Usage: $0 {update|revert|clean}"
    echo
    echo "Commands:"
    echo "  update       Update SSL certificate using Let's Encrypt"
    echo "  revert [id]  Revert to previous certificate backup (optional: specific backup id)"
    echo "  clean        Clean up temporary files and acme.sh installation"
    echo
    echo "Example:"
    echo "  $0 update"
    echo "  $0 revert 20240315123456"
}

# Execute the command
case "$1" in
    update)  updateCrt ;;
    revert)  revertCrt "$2" ;;
    clean)   cleanUp ;;
    help|--help|-h)
        show_help
        exit 0
        ;;
    *)
        show_help
        exit 1
        ;;
esac
