#!/bin/bash

# install.sh - Cai dat Cong cu N8N Host

# --- Dinh nghia mau sac va bien ---
RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
CYAN='\e[1;36m'
NC='\e[0m'

# URL cua script chinh (thay doi thanh link thuc te)
SCRIPT_URL="https://raw.githubusercontent.com/ducvps12/n8n/refs/heads/main/n8n-host.sh"
# URL cua file template
TEMPLATE_URL="https://raw.githubusercontent.com/ducvps12/n8n/refs/heads/main/import-workflow-credentials.json"

SCRIPT_NAME="n8n-host"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
TEMP_SCRIPT="/tmp/${SCRIPT_NAME}.sh-$(date +%s%N)-${RANDOM}"
TEMPLATE_FILE_NAME="import-workflow-credentials.json"
TEMPLATE_DIR="/n8n-templates"
INSTANCES_DIR="/n8n-instances"

# --- Ham phu tro ---
generate_random_string() {
    local length="${1:-16}"
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length" 2>/dev/null
}

# --- Ham kiem tra quyen root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}[!] Loi: Ban can chay script cai dat nay voi quyen root (sudo).${NC}\n"
        exit 1
    fi
}

# --- Ham kiem tra lenh (curl hoac wget) ---
check_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
    elif command -v wget &> /dev/null; then
        DOWNLOADER="wget"
    else
        echo -e "${RED}[!] Loi: Khong tim thay 'curl' hoac 'wget'. Vui long cai dat mot trong hai cong cu nay.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[*] Su dung '$DOWNLOADER' de tai file.${NC}"
}

# --- Ham tai file ---
download_file() {
    local url="$1"
    local output="$2"
    echo -e "${YELLOW}[*] Dang tai file tu: ${url}${NC}"
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -fsSL -o "$output" "$url"
        local download_status=$?
    else
        wget -qO "$output" "$url"
        local download_status=$?
    fi

    if [[ $download_status -ne 0 ]]; then
        echo -e "${RED}[!] Loi: Tai file that bai (kiem tra URL hoac ket noi mang).${NC}"
        rm -f "$output"
        return 1
    fi

    if [[ ! -s "$output" ]]; then
        echo -e "${RED}[!] Loi: File tai ve rong (kiem tra URL).${NC}"
        rm -f "$output"
        return 1
    fi

    echo -e "${GREEN}[+] Tai file thanh cong.${NC}"
    return 0
}

# --- Ham go bo cai dat ---
uninstall_script() {
    check_root
    echo -e "${YELLOW}[*] Bat dau qua trinh go bo ${SCRIPT_NAME}...${NC}"

    if [[ ! -f "$INSTALL_PATH" ]]; then
        echo -e "${YELLOW}[!] Khong tim thay ${SCRIPT_NAME} tai ${INSTALL_PATH}. Khong co gi de go bo.${NC}"
        exit 0
    fi

    echo -e "${YELLOW}[*] Xoa file ${INSTALL_PATH}...${NC}"
    if ! sudo rm -f "$INSTALL_PATH"; then
        echo -e "${RED}[!] Loi: Khong the xoa ${INSTALL_PATH}.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[*] Xoa thu muc ${TEMPLATE_DIR} (neu trong)...${NC}"
    if [[ -d "$TEMPLATE_DIR" && -z "$(ls -A "$TEMPLATE_DIR")" ]]; then
        sudo rm -rf "$TEMPLATE_DIR"
    fi

    echo -e "\n${GREEN}[+] Go bo ${SCRIPT_NAME} thanh cong!${NC}"
    exit 0
}

# --- Ham cai dat ---
install_script() {
    echo -e "${YELLOW}[*] Bat dau qua trinh cai dat ${SCRIPT_NAME}...${NC}"

    # 1. Kiem tra quyen root
    check_root

    # 2. Kiem tra cong cu tai file
    check_downloader

    # 3. Kiem tra quyen ghi thu muc cai dat
    if [[ ! -w "$INSTALL_DIR" ]]; then
        echo -e "${RED}[!] Loi: Khong co quyen ghi vao ${INSTALL_DIR}.${NC}"
        exit 1
    fi

    # 4. Tai script chinh
    if ! download_file "$SCRIPT_URL" "$TEMP_SCRIPT"; then
        exit 1
    fi

    # 5. Tao thu muc cai dat neu chua co
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo -e "${YELLOW}[*] Tao thu muc cai dat: ${INSTALL_DIR}${NC}"
        if ! sudo mkdir -p "$INSTALL_DIR"; then
            echo -e "${RED}[!] Loi: Khong the tao thu muc ${INSTALL_DIR}.${NC}"
            rm -f "$TEMP_SCRIPT"
            exit 1
        fi
    fi

    # 6. Di chuyen script vao thu muc cai dat
    echo -e "${YELLOW}[*] Di chuyen script den: ${INSTALL_PATH}${NC}"
    if ! sudo mv "$TEMP_SCRIPT" "$INSTALL_PATH"; then
        echo -e "${RED}[!] Loi: Khong the di chuyen script den ${INSTALL_PATH}.${NC}"
        rm -f "$TEMP_SCRIPT"
        exit 1
    fi

    # 7. Cap quyen thuc thi cho script
    echo -e "${YELLOW}[*] Cap quyen thuc thi cho script...${NC}"
    if ! sudo chmod +x "$INSTALL_PATH"; then
        echo -e "${RED}[!] Loi: Khong the cap quyen thuc thi cho ${INSTALL_PATH}.${NC}"
        sudo rm -f "$INSTALL_PATH"
        exit 1
    fi

    # 8. Tao thu muc n8n-templates va n8n-instances
    echo -e "${YELLOW}[*] Tao thu muc ${TEMPLATE_DIR} va ${INSTANCES_DIR}...${NC}"
    for dir in "$TEMPLATE_DIR" "$INSTANCES_DIR"; do
        if [[ ! -d "$dir" ]]; then
            if ! sudo mkdir -p "$dir"; then
                echo -e "${RED}[!] Loi: Khong the tao thu muc ${dir}.${NC}"
                sudo rm -f "$INSTALL_PATH"
                exit 1
            fi
            sudo chmod 755 "$dir"
        fi
    done

    # 9. Tai file template
    echo -e "${YELLOW}[*] Tai ve file template...${NC}"
    local temp_template="/tmp/${TEMPLATE_FILE_NAME}-$(generate_random_string)"
    if ! download_file "$TEMPLATE_URL" "$temp_template"; then
        sudo rm -f "$INSTALL_PATH"
        exit 1
    fi

    # Kiem tra noi dung file template co phai JSON hop le khong
    if ! jq . "$temp_template" >/dev/null 2>&1; then
        echo -e "${RED}[!] Loi: File template tai ve khong phai JSON hop le.${NC}"
        rm -f "$temp_template"
        sudo rm -f "$INSTALL_PATH"
        exit 1
    fi

    # Di chuyen file template vao thu muc
    if ! sudo mv "$temp_template" "${TEMPLATE_DIR}/${TEMPLATE_FILE_NAME}"; then
        echo -e "${RED}[!] Loi: Khong the di chuyen file template den ${TEMPLATE_DIR}/${TEMPLATE_FILE_NAME}.${NC}"
        sudo rm -f "$INSTALL_PATH"
        exit 1
    fi
    sudo chmod 644 "${TEMPLATE_DIR}/${TEMPLATE_FILE_NAME}"

    # 10. Kiem tra lai
    if [[ -f "$INSTALL_PATH" && -x "$INSTALL_PATH" ]]; then
        echo -e "\n${GREEN}[+++] Cai dat ${SCRIPT_NAME} thanh cong!${NC}"
        echo -e "Ban co the chay cong cu bang lenh: ${CYAN}${SCRIPT_NAME}${NC}"
        echo -e "De go bo, chay lenh: ${CYAN}bash $0 --uninstall${NC}"
        echo -e "De tao instance N8N moi, chay: ${CYAN}${SCRIPT_NAME}${NC} va chon tuy chon 11."
    else
        echo -e "\n${RED}[!] Cai dat that bai. Khong tim thay file thuc thi tai ${INSTALL_PATH}.${NC}"
        sudo rm -f "$INSTALL_PATH"
        exit 1
    fi
}

# --- Xu ly tham so dong lenh ---
case "$1" in
    --uninstall)
        uninstall_script
        ;;
    --force-install)
        check_root
        echo -e "${YELLOW}[*] Buoc cai dat lai ${SCRIPT_NAME}...${NC}"
        sudo rm -f "$INSTALL_PATH"
        install_script
        ;;
    "")
        if [[ -f "$INSTALL_PATH" ]]; then
            echo -e "${YELLOW}[!] Cong cu '${SCRIPT_NAME}' da duoc cai dat tai '${INSTALL_PATH}'.${NC}"
            echo -e "Neu ban muon cai dat lai, hay chay: ${CYAN}bash $0 --force-install${NC}"
            echo -e "Neu ban muon go bo, hay chay: ${CYAN}bash $0 --uninstall${NC}"
            exit 1
        else
            install_script
        fi
        ;;
    *)
        echo -e "${RED}[!] Tham so khong hop le: $1${NC}"
        echo -e "Cach dung:"
        echo -e "  Cai dat: ${CYAN}bash $0${NC}"
        echo -e "  Cai dat lai: ${CYAN}bash $0 --force-install${NC}"
        echo -e "  Go bo: ${CYAN}bash $0 --uninstall${NC}"
        exit 1
        ;;
esac

exit 0
