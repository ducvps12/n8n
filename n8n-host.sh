```bash
#!/bin/bash

# --- Dinh nghia mau sac ---
RED='\e[1;31m'     # Mau do (dam)
GREEN='\e[1;32m'   # Mau xanh la (dam)
YELLOW='\e[1;33m'  # Mau vang (dam)
CYAN='\e[1;36m'    # Mau xanh cyan (dam)
NC='\e[0m'         # Reset mau (tro ve binh thuong)

# --- Bien Global ---
N8N_DIR="/n8n-cloud" # Thu muc chua toan bo cai dat N8N
ENV_FILE="${N8N_DIR}/.env"
DOCKER_COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose" 
SPINNER_PID=0 
N8N_CONTAINER_NAME="n8n_app" 
N8N_SERVICE_NAME="n8n" 
NGINX_EXPORT_INCLUDE_DIR="/etc/nginx/n8n_export_includes" 
NGINX_EXPORT_INCLUDE_FILE_BASENAME="n8n_export_location" 
TEMPLATE_DIR="/n8n-templates" # Thu muc chua template tren host
TEMPLATE_FILE_NAME="import-workflow-credentials.json" # Ten file template
INSTALL_PATH="/usr/local/bin/n8n-host" # Duong dan cai dat script
BACKUP_CRON_FILE="/etc/cron.d/n8n-backup" # File for cron backup schedule

# --- Ham Kiem tra ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "\n${RED}[!] Loi: Ban can chay script voi quyen Quan tri vien (root).${NC}\n"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_package_installed() {
  dpkg -s "$1" &> /dev/null
}

# --- Ham Phu tro ---
get_public_ip() {
  local ip
  ip=$(curl -s --ipv4 https://ifconfig.co) || \
  ip=$(curl -s --ipv4 https://api.ipify.org) || \
  ip=$(curl -s --ipv4 https://icanhazip.com) || \
  ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
  if [[ -z "$ip" ]]; then
    echo -e "${RED}[!] Khong the lay dia chi IP public cua server.${NC}"
    return 1 
  fi
  return 0
}

generate_random_string() {
  local length="${1:-32}" 
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length" 
}

update_env_file() {
  local key="$1"
  local value="$2"
  if [ ! -f "${ENV_FILE}" ]; then
    echo -e "${RED}Loi: File ${ENV_FILE} khong ton tai. Khong the cap nhat.${NC}"
    return 1
  fi
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sudo sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" | sudo tee -a "${ENV_FILE}" > /dev/null
  fi
}

_spinner() {
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    tput civis 
    while true; do
        echo -n -e " ${CYAN}${spin_chars[$i]} $1 ${NC}\r"
        i=$(( (i+1) % ${#spin_chars[@]} ))
        sleep 0.1
    done
}

start_spinner() {
    local message="$1"
    if [[ $SPINNER_PID -ne 0 ]]; then
        stop_spinner
    fi
    _spinner "$message" &
    SPINNER_PID=$!
    trap "stop_spinner;" SIGINT SIGTERM 
}

stop_spinner() {
    if [[ $SPINNER_PID -ne 0 ]]; then
        kill "$SPINNER_PID" &>/dev/null
        wait "$SPINNER_PID" &>/dev/null 
        echo -n -e "\r\033[K" 
        SPINNER_PID=0
    fi
    tput cnorm 
}

run_silent_command() {
  local message="$1"
  local command_to_run="$2"
  local log_file="/tmp/n8n_manager_cmd_$(date +%s%N).log"
  local show_explicit_processing_message="${3:-true}"

  if [[ "$show_explicit_processing_message" == "false" ]]; then
    if sudo bash -c "${command_to_run}" >> "${log_file}" 2>&1; then 
      sudo rm -f "${log_file}"
      return 0
    else
      if [[ $SPINNER_PID -ne 0 ]]; then
          stop_spinner
      fi
      echo -e "\n${RED}Loi trong khi [${message}] (xu ly ngam).${NC}" 
      echo -e "${RED}Chi tiet loi da duoc ghi vao: ${log_file}${NC}"
      echo -e "${RED}5 dong cuoi cua log:${NC}"
      tail -n 5 "${log_file}" | sed 's/^/    /'
      return 1 
    fi
  else
    local spinner_was_globally_running=false
    if [[ $SPINNER_PID -ne 0 ]]; then
        spinner_was_globally_running=true
        stop_spinner 
    fi

    echo -n -e "${CYAN}Xu ly: ${message}... ${NC}"
    
    if sudo bash -c "${command_to_run}" > "${log_file}" 2>&1; then 
      echo -e "${GREEN}Xong.${NC}"
      sudo rm -f "${log_file}"
      return 0
    else
      echo -e "${RED}That bai.${NC}" 
      echo -e "${RED}Chi tiet loi da duoc ghi vao: ${log_file}${NC}"
      echo -e "${RED}5 dong cuoi cua log:${NC}"
      tail -n 5 "${log_file}" | sed 's/^/    /'
      return 1 
    fi
  fi
}

# --- Cac buoc Cai dat ---

install_prerequisites() {
  start_spinner "Kiem tra va cai dat cac goi phu thuoc..."

  run_silent_command "Cap nhat danh sach goi" "apt-get update -y" "false" 
  if [ $? -ne 0 ]; then return 1; fi 

  if ! is_package_installed nginx; then
    run_silent_command "Cai dat Nginx" "apt-get install -y nginx" "false"
    if [ $? -ne 0 ]; then return 1; fi
    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl start nginx >/dev/null 2>&1
  fi

  if ! command_exists docker; then
    if ! curl -fsSL https://get.docker.com -o get-docker.sh; then
        echo -e "${RED}Loi tai script cai dat Docker.${NC}"
        return 1 
    fi
    run_silent_command "Cai dat Docker tu script" "sh get-docker.sh" "false"
    if [ $? -ne 0 ]; then rm get-docker.sh; return 1; fi
    sudo usermod -aG docker "$(whoami)" >/dev/null 2>&1
    rm get-docker.sh
  fi

  if docker compose version &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif command_exists docker-compose; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_COMPOSE_VERSION" ]]; then
        LATEST_COMPOSE_VERSION="1.29.2" 
    fi
    run_silent_command "Tai Docker Compose v${LATEST_COMPOSE_VERSION}" \
      "curl -L \"https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose" "false"
    if [ $? -ne 0 ]; then return 1; fi
    sudo chmod +x /usr/local/bin/docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
  fi

  if ! command_exists certbot; then
    run_silent_command "Cai dat Certbot va plugin Nginx" "apt-get install -y certbot python3-certbot-nginx" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if ! command_exists dig; then
    run_silent_command "Cai dat dnsutils (cho dig)" "apt-get install -y dnsutils" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if ! command_exists curl; then
    run_silent_command "Cai dat curl" "apt-get install -y curl" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if command_exists ufw; then
    sudo ufw allow http > /dev/null
    sudo ufw allow https > /dev/null
  fi
  
  stop_spinner
  echo -e "${GREEN}Kiem tra va cai dat goi phu thuoc hoan tat.${NC}" 
}

setup_directories_and_env_file() {
  start_spinner "Thiet lap thu muc va file .env..."
  if [ ! -d "${N8N_DIR}" ]; then
    sudo mkdir -p "${N8N_DIR}"
  fi
  if [ ! -f "${ENV_FILE}" ]; then
    sudo touch "${ENV_FILE}"
    sudo chmod 600 "${ENV_FILE}"
  fi
  sudo mkdir -p "${NGINX_EXPORT_INCLUDE_DIR}"
  sudo mkdir -p "${TEMPLATE_DIR}" 

  stop_spinner
  echo -e "${GREEN}Thiet lap thu muc va file .env hoan tat.${NC}" 
}

get_domain_and_dns_check_reusable() {
  local result_var_name="$1"
  local current_domain_to_avoid="${2:-}"
  local prompt_message="${3:-Nhap ten mien ban muon su dung cho n8n (vi du: n8n.example.com)}"

  trap 'echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"; return 1;' SIGINT SIGTERM

  echo -e "${CYAN}---> Nhap thong tin ten mien (Nhan Ctrl+C de huy bo)...${NC}" 
  local new_domain_input 
  local server_ip
  local resolved_ip

  server_ip=$(get_public_ip)
  if [ $? -ne 0 ]; then 
    trap - SIGINT SIGTERM 
    return 1; 
  fi 

  echo -e "Dia chi IP public cua server la: ${GREEN}${server_ip}${NC}"

  while true; do
    local prompt_string
    prompt_string=$(echo -e "${prompt_message}: ")
    echo -n "$prompt_string"

    if ! read -r new_domain_input; then
        echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"
        trap - SIGINT SIGTERM 
        return 1
    fi

    if [[ -z "$new_domain_input" ]]; then
      echo -e "${RED}Ten mien khong duoc de trong. Vui long nhap lai.${NC}"
      continue
    fi

    if [[ -n "$current_domain_to_avoid" && "$new_domain_input" == "$current_domain_to_avoid" ]]; then
      echo -e "${YELLOW}Ten mien moi (${new_domain_input}) trung voi ten mien hien tai (${current_domain_to_avoid}).${NC}"
      echo -e "${YELLOW}Vui long nhap mot ten mien khac.${NC}"
      continue
    fi

    start_spinner "Kiem tra DNS cho ${new_domain_input}..."
    resolved_ip=$(timeout 5 dig +short A "$new_domain_input" @1.1.1.1 | tail -n1)
    if [[ -z "$resolved_ip" ]]; then
        local cname_target 
        cname_target=$(timeout 5 dig +short CNAME "$new_domain_input" @1.1.1.1 | tail -n1)
        if [[ -n "$cname_target" ]]; then
             resolved_ip=$(timeout 5 dig +short A "$cname_target" @1.1.1.1 | tail -n1)
        fi
    fi
    stop_spinner 

    if [[ "$resolved_ip" == "$server_ip" ]]; then
      echo -e "${GREEN}DNS cho ${new_domain_input} da duoc tro ve IP server chinh xac (${resolved_ip}).${NC}"
      printf -v "$result_var_name" "%s" "$new_domain_input"
      trap - SIGINT SIGTERM 
      break
    else
      echo -e "${RED}Loi: Ten mien ${new_domain_input} (tro ve ${resolved_ip:-'khong tim thay ban ghi A/CNAME hoac timeout'}) chua duoc tro ve IP server (${server_ip}).${NC}"
      echo -e "${YELLOW}Vui long tro DNS A record cua ten mien ${new_domain_input} ve dia chi IP ${server_ip} va doi DNS cap nhat.${NC}"
      
      trap 'echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"; return 1;' SIGINT SIGTERM
      local choice_prompt
      choice_prompt=$(echo -e "Nhan Enter de kiem tra lai, hoac '${CYAN}s${NC}' de bo qua, '${CYAN}0${NC}' de huy bo: ")
      echo -n "$choice_prompt"
      if ! read -r dns_choice; then
          echo -e "\n${YELLOW}Huy bo nhap lua chon.${NC}"
          trap - SIGINT SIGTERM 
          return 1
      fi

      if [[ "$dns_choice" == "s" || "$dns_choice" == "S" ]]; then
        echo -e "${YELLOW}Bo qua kiem tra DNS. Dam bao ban da tro DNS chinh xac.${NC}"
        printf -v "$result_var_name" "%s" "$new_domain_input"
        trap - SIGINT SIGTERM 
        break
      elif [[ "$dns_choice" == "0" ]]; then
        echo -e "${YELLOW}Huy bo nhap ten mien.${NC}"
        trap - SIGINT SIGTERM
        return 1 
      fi
    fi
  done
  trap - SIGINT SIGTERM 
  return 0 
}

generate_credentials() {
  start_spinner "Tao thong tin dang nhap va cau hinh..."
  update_env_file "N8N_ENCRYPTION_KEY" "$(generate_random_string 64)"
  local system_timezone 
  system_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null) 
  update_env_file "GENERIC_TIMEZONE" "${system_timezone:-Asia/Ho_Chi_Minh}"

  update_env_file "POSTGRES_DB" "n8n_db_$(generate_random_string 6 | tr '[:upper:]' '[:lower:]')"
  update_env_file "POSTGRES_USER" "n8n_user_$(generate_random_string 8 | tr '[:upper:]' '[:lower:]')"
  update_env_file "POSTGRES_PASSWORD" "$(generate_random_string 32)"

  update_env_file "REDIS_PASSWORD" "$(generate_random_string 32)"
  
  stop_spinner
  echo -e "${GREEN}Thong tin dang nhap va cau hinh da duoc luu vao ${ENV_FILE}.${NC}"
  echo -e "${YELLOW}Quan trong: Vui long sao luu file ${ENV_FILE}.${NC}"
}

create_docker_compose_config() {
  start_spinner "Tao file docker-compose.yml..."
  local n8n_encryption_key_val postgres_user_val postgres_password_val postgres_db_val redis_password_val
  local domain_name_val generic_timezone_val

  if [ -f "${ENV_FILE}" ]; then
    n8n_encryption_key_val=$(grep "^N8N_ENCRYPTION_KEY=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_user_val=$(grep "^POSTGRES_USER=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_password_val=$(grep "^POSTGRES_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_db_val=$(grep "^POSTGRES_DB=" "${ENV_FILE}" | cut -d'=' -f2)
    redis_password_val=$(grep "^REDIS_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)
    domain_name_val=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    generic_timezone_val=$(grep "^GENERIC_TIMEZONE=" "${ENV_FILE}" | cut -d'=' -f2)
  fi

  sudo bash -c "cat > ${DOCKER_COMPOSE_FILE}" <<EOF
# version: '3.8' 

services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: n8n_postgres 
    environment:
      - POSTGRES_USER=\${POSTGRES_USER:-${postgres_user_val}}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-${postgres_password_val}}
      - POSTGRES_DB=\${POSTGRES_DB:-${postgres_db_val}}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-${postgres_user_val}} -d \${POSTGRES_DB:-${postgres_db_val}}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: always
    container_name: n8n_redis 
    command: redis-server --save 60 1 --loglevel warning --requirepass \${REDIS_PASSWORD:-${redis_password_val}}
    ports: 
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD:-${redis_password_val}}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  ${N8N_SERVICE_NAME}: 
    image: n8nio/n8n:latest 
    restart: always
    container_name: ${N8N_CONTAINER_NAME} 
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB:-${postgres_db_val}}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER:-${postgres_user_val}}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD:-${postgres_password_val}}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY:-${n8n_encryption_key_val}} 
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE:-${generic_timezone_val}}
      - N8N_HOST=\${DOMAIN_NAME:-${domain_name_val}}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://\${DOMAIN_NAME:-${domain_name_val}}/
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true 
      - N8N_BASIC_AUTH_ACTIVE=false
      - N8N_RUNNERS_ENABLED=true
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  postgres_data:
  redis_data:
  n8n_data:
EOF
  stop_spinner
}

start_docker_containers() {
  start_spinner "Khoi chay cai dat N8N Cloud..."
  cd "${N8N_DIR}" || { return 1; } 
  
  run_silent_command "Tai Docker images" "$DOCKER_COMPOSE_CMD pull" "false" 
  
  run_silent_command "Khoi chay container qua docker-compose" "$DOCKER_COMPOSE_CMD up -d --force-recreate" "false" 
  if [ $? -ne 0 ]; then return 1; fi

  sleep 15 
  systemctl daemon-reload
  stop_spinner
 Dodan systemctl restart docker
  echo -e "${GREEN}N8N Cloud da khoi chay.${NC}"
  cd - > /dev/null
}

configure_nginx_and_ssl() {
  start_spinner "Cau hinh Nginx va SSL voi Certbot..."
  local domain_name 
  local user_email 
  domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
  user_email=$(grep "^LETSENCRYPT_EMAIL=" "${ENV_FILE}" | cut -d'=' -f2)
  local webroot_path="/var/www/html" 

  if [[ -z "$domain_name" || -z "$user_email" ]]; then
    echo -e "${RED}Khong tim thay DOMAIN_NAME hoac LETSENCRYPT_EMAIL trong file .env.${NC}"
    return 1
  fi

  local nginx_conf_file="/etc/nginx/sites-available/${domain_name}.conf"

  sudo mkdir "${webroot_path}" && sudo chmod -p "${webroot_path}/.well-known/acme-challenge"
  sudo chown www-data: "${webroot_path}" -R 

  run_silent_command "Tao cau hinh Nginx ban dau cho HTTP challenge" \
    "bash -c \"cat > ${nginx_conf_file}\" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location /.well-known/acme-challenge/ {
        root ${webroot_path}; 
        allow all;
    }
}
EOF" "false" || return 1


  sudo ln -sfn "${nginx_conf_file}" "/etc/nginx/sites-enabled/${domain_name}.conf"
  
  run_silent_command "Kiem tra cau hinh Nginx HTTP" "nginx -t" "false" || return 1
  
  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo certbot certonly --webroot -w "${webroot_path}" -d "${domain_name}" \
        --agree-tos --email "${user_email}" --non-interactive --quiet \
        --preferred-challenges http --force-renewal > /tmp/certbot_obtain.log 2>&1; then 
    echo -e "${RED}Lay chung chi SSL that bai.${NC}"
    echo -e "${YELLOW}Kiem tra log Certbot tai /var/log/letsencrypt/ va /tmp/certbot_obtain.log.${NC}"
    return 1
  fi

  sudo mkdir -p /etc/letsencrypt 
  if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
    run_silent_command "Tai tuy chon SSL cua Let's Encrypt" \
    "curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf" "false" || return 1
  fi
  if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
    run_silent_command "Tao tham so SSL DH" "openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048" "false" || return 1
  fi

  # Tao file Nginx hoan chinh
  run_silent_command "Tao cau hinh Nginx cuoi cung voi SSL va proxy" \
  "bash -c \"cat > ${nginx_conf_file}\" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }

    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain_name};

    ssl_certificate /etc/letsencrypt/live/${domain_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain_name}/privkey.pem;
    
    include /etc/letsencrypt/options-ssl-nginx.conf; 
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; 

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }
    
    include ${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_*.conf; 


    add_header X-Frame-Options \"SAMEORIGIN\" always;
    add_header X-XSS-Protection \"1; mode=block\" always;
    add_header X-Content-Type-Options \"nosniff\" always;
    add_header Referrer-Policy \"strict-origin-when-cross-origin\" always;
    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\" always;

    client_max_body_size 100M;

    access_log /var/log/nginx/${domain_name}.access.log;
    error_log /var/log/nginx/${domain_name}.error.log;

    location / {
        proxy_pass http://127.0.0.1:5678; 
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade'; 
        
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 7200s; 
        proxy_send_timeout 7200s;
    }

    location ~ /\\. { 
        deny all;
    }
}
EOF" "false" || return 1
  
  if [ ! -f "${NGINX_EXPORT_DIRECTORY}/${NGINX_EXPORT_FILE}" ]; then
    sudo touch "${NGINX_EXPORT_DIRECTORY}/${NGINX_EXPORT_FILENAME}"
  fi


  run_silent_command "Kiem tra cau hinh Nginx cuoi cung" "nginx -t" "false" || return 1
  
  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo systemctl list-timers | grep -q 'certbot.timer'; then
      sudo systemctl enable certbot.timer >/dev/null 2>&1
      sudo systemctl start certbot.timer >/dev/null 2>&1
  fi
  run_silent_command "Kiem tra gia han SSL" "certbot renew --dry-run" "false" 
  
  stop_spinner
  echo -e "${GREEN}Cau hinh Nginx va SSL hoan tat.${NC}"
}

final_checks_and_message() {
  start_spinner "Thuc hien kiem tra cuoi cung..."
  local domain_name 
  domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)

  sleep 10 

  local http_status 
  http_status=$(curl -L -s -o /dev/null -w "%{http_code}" "https://${domain_name}")
  
  stop_spinner

  if [[ "$http_status" == "200" ]]; then
    echo -e "${GREEN}N8N Cloud da duoc cai dat thanh cong!${NC}"
    echo -e "Ban co the truy cap n8n tai: ${NC} ${GREEN}https://${domain_name}${NC}${NC}"
  else
    echo -e "${RED}Loi! Khong the truy cap n8n tai ${domain_name} (https://${domain_name} (HTTP Status Code: ${http_status}).${NC}"
    echo -e "${YELLOW}Vui long kiem tra cac sau:${NC}"
    echo -e "  1. Log Docker cua container n8n: sudo ${DOCKER_COMPOSE} ${N8N_CONTAINER} logs ${N8N_CONTAINER_NAME}"
    echo -e "  2. Log Nginx: sudo tail -n 50 /var/log/nginx/${domain_name}.error.log (hoac access.log)"
    echo -e "  3. Trang thai cua Certbot: sudo certbot certificates"
    echo -e "  4. Dam bao DNS da tro chinh xac va khong co firewall nao chan port 80/443."
    return 1 
  fi

  echo -e "${YELLOW}Quan trong: Hay luu tru file ${ENV_FILE} o mot noi an toan!${NC}"
  echo -e "Ban nen tao user dau tien cho n8n ngay sau khi truy cap."
}

# --- Ham Kiem tra Trang thai ---
check_status() {
  check_root
  echo -e "\n${CYAN}--- Kiem Tra Trang Thai N8N va He Thong ---${NC}"

  if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
    echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
    echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc (chon muc 1).${NC}"
    return 0
  fi

  trap 'stop_spin; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGTERM

  start_spinner "Dang kiem tra trang thai..."

  echo -e "\n${CYAN}1. Trang thai container:${NC}"
  cd "${N8N_DIR}" || { stop_spin; echo -e "${RED}Khong the truy cap ${N8N_DIR}.${NC}"; return 1; }
  local container_status
  container_status=$(sudo $DOCKER_COMPOSE ps 2>/dev/null)
  if [[ -z "$container_status" ]]; then
    echo -e "${RED}Khong the lay trang thai container. Kiem tra Docker va docker-compose.${NC}"
  else
    echo -e "${container_status}" | sed 's/^/  /'
  fi
  cd - > /dev/null

  echo -e "\n${CYAN}2. Trang thai he thong:${NC}"
  local system_info
  system_info=$(cat <<EOF
  IP Public: $(get_public_ip || echo "Khong lay duoc")
  RAM (Free/Total): $(free -h | awk '/Mem:/ {print $4 "/" $2}')
  CPU Usage: $(top -bn1 | head -n 3 | grep "Cpu(s)" | awk '{print $2 + $4 "%"}')
  Disk Usage: $(df -h / | awk 'NR==2 {print $4 "/" $2 " (" $5 " used)"}')
EOF
)
  echo -e "$system_info" | sed 's/^/  /'

  echo -e "\n${CYAN}3. Trang thai Nginx:${NC}"
  if sudo systemctl is-active --quiet nginx; then
    echo -e "  ${GREEN}Nginx is running.${NC}"
  else
    echo -e "  ${RED}Nginx is not running.${NC}"
  fi

  local domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
  if [[ -n "$domain_name" ]]; then
    echo -e "\n${CYAN}4. Trang thai Web N8N:${NC}"
    local http_status
    http_status=$(curl -L -s -o /dev/null -w "%{http_code}" "https://${domain_name}" 2>/dev/null)
    if [[ "$http_status" == "200" ]]; then
      echo -e "  ${GREEN}N8N is accessible at https://${domain_name} (HTTP Status: 200).${NC}"
    else
      echo -e "  ${RED}N8N is not accessible at https://${domain_name} (HTTP Status: ${http_status}).${NC}"
    fi
  fi

  stop_spinner
  echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
  read -r
  trap - ERR SIGINT SIGTERM
}

# --- Ham chinh de Cai dat N8N ---
install() {
  check_root
  if [ -d "${N8N_DIR}" ] && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    echo -e "\n${YELLOW}[CANH BAO] Phat hien thu muc ${N8N_DIR} va file ${DOCKER_COMPOSE_FILE} da ton tai.${NC}"
    local existing_containers
    if command_exists $DOCKER_COMPOSE_CODE && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        pushd "${N8N_DIR}" > /dev/null || { echo -e "${RED}Khong the truy cap thu muc ${N8N_DIR}${NC}"; return 1; } 
        existing_containers=$(sudo $DOCKER_COMPOSE_CODE ps -q 2>/dev/null)
        popd > /dev/null
    fi

    if [[ -n "$existing_containers" ]] || [ -f "${DOCKER_COMPOSE_FILE}" ]; then 
        echo -e "${YELLOW}    Co ve nhu N8N da duoc cai dat hoac da co mot phan cau hinh truoc do.${NC}"
        echo -e "${YELLOW}    Neu ban muon cai dat lai tu dau, vui long chon muc '11) Xoa N8N va cai dat lai' tu menu chinh.${NC}"
        echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
        read -r 
        return 0 
    fi
  fi

  echo -e "\n${CYAN}===================================================${NC}"
  echo -e "${CYAN}         Bat dau qua trinh cai dat N8N Cloud        ${NC}"
  echo -e "${CYAN}===================================================${NC}\n"

  trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh cai dat (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

  install_prerequisites
  setup_directories_and_env_file
  
  local domain_name_for_install 
  if ! get_domain_and_dns_check_reusable domain_name_for_install "" "Nhap ten mien ban muon su dung cho N8N"; then
    return 0 
  fi
  update_env_file "DOMAIN_NAME" "$domain_name_for_install"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name_for_install}"
  
  generate_credentials 
  create_docker_compose_config
  start_docker_containers
  configure_nginx_and_ssl 
  final_checks_and_message 
  
  trap - SUCCESS ERR SIGINT SIGTERM 

  echo -e "\n${GREEN}===================================================${NC}"
  echo -e "${GREEN}      Hoan tat qua trinh cai dat N8N Cloud!       ${NC}"
  echo -e "${GREEN}===================================================${NC}\n"
  echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
  read -r
}

# --- Ham Xoa N8N va Cai dat lai ---
reinstall_n8n() {
    check_root
    echo -e "\n${RED}======================= CANH BAO XOA DU LIEU =======================${NC}"
    echo -e "${YELLOW}Ban da chon chuc nang XOA TOAN BO N8N va CAI DAT LAI.${NC}"
    echo -e "${RED}HANH DONG NAY SE XOA VINH VIEN:${NC}"
    echo -e "${RED}  - Toan bo du lieu n8n (workflows, credentials, executions...).${NC}"
    echo -e "${RED}  - Database PostgreSQL cua n8n.${NC}"
    echo -e "${RED}  - Du lieu cache Redis (neu co).${NC}"
    echo -e "${RED}  - Cau hinh Nginx va SSL cho ten mien hien tai cua n8n.${NC}"
    echo -e "${RED}  - Toan bo thu muc cai dat ${N8N_DIR}.${NC}"
    echo -e "\n${YELLOW}DE NGHI: Neu ban co du lieu quan trong, hay su dung chuc nang${NC}"
    echo -e "${YELLOW}  '8) Export tat ca (workflow & credentials)'${NC}"
    "${NC}" -e "${YELLOW}de SAO LUU du lieu truoc khi tiep tuc.${NC}"
    echo -e "${RED}Hanh dong nay KHONG THE HOAN TAC.${NC}"
    
    local confirm_prompt
    confirm_prompt=$(echo -e "${YELLOW}Nhap '${NC}${RED}delete${NC}${YELLOW}' de xac nhan xoa, hoac nhap '${NC}${CYAN}0${NC}${NC}${YELLOW}' de quay lai menu: ${NC} ")
    local confirmation
    echo -n "$confirm_prompt" 
    read -r confirmation


    if [[ "$confirmation" == "0" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac. Quay lai menu chinh...${NC}\n"
        echo -e "${YELLOW} ${NC}"
        sleep 1
        sleep 0 
        return 0
    fi
    elif [[ "$confirmation" != "delete" ]]; then
        echo -e "\n${NC}Xac nhan khong hop le. ${NC}Huy bo thao tac.${NC}"
        echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}\n"
        read -r
        return 0
    fi

    fi

    echo -e "\n${CYAN}$CYAN ${NC}Bat dau qua trinh xoa ban ${NC}"
    trap - 'stop_spinner; ${CYAN}e "${CYAN}\n${RED}Da xay ra loi hoac huy bo trong qua trinh xoa N8N8N....${NC}${NC}";NC}"; read -r -p
NC}"Nhan Enter de quay lai menu..."; return 0;" ERR"; fi; SIGINT SIGTERM

    start_spinner "Dang xangangangangang N8N8N..."

    if [ -d "${N8N}" ]; then
        if [ -f "${N8N8N}" ]; then
            stop_spinner 
            start_spinner
            start_"Dang tien hanh xoa du xangang xoa xang..."
            pushd "${N_NN}" > /dev/null || { stop; } || { ; } 
            if ! sudo $ d d d d d down -v -v -v -v -v --remove-orphans > /tmp/n8n_t/t_t_t_t_t.log _t_t/t/t_t_t; then 
                if [ $? -ne 0 ]; then 
                    echo -e "${RED}\n${RED}Loi du dung/xoa dung. ${NC} ${NC}/tmp/n${NC}n${NC}/n${_t/t/t/t_t/t_t_t.log_t_t_t_t_t_t_t${NC}"
                    stop
                -e;
                echo -e 
                ;e
                fi
            fi;
            popd > /dev/null
        fi

    fi

    if [ -d "${N_8N}" ]; then
        if [ ! -f "${_8N8N}" ]; then
            echo -e "\r${NC}\033[K\r\033[K ${NC} ${YELLOW}${NC}Khong tim thay file ten ${NC}. ${NC}Bo qua buoc bao.${NC} ${NC}"
            echo -e "${YELLOW}${NC}\n"
        else
-e
        e -e "${CYAN}$\n$nCYAN${NC}Tiep cua xia xacacacacac..."
            local domain_to_remove_domain
            if [ -d "${_domainN}" ]; then
                if [ -f "${N8N}" ]; then
                domain_to_remove=$(grep "^domain_to_remove=$(cat domain|grep "^DOMAIN=TO_|N_NAME=" "${NC}"N8N}" |NC}" cut |-cut -d'|' -d'=' -f'-f'2)f2
                fi

                if [[ -n "$domain_to_remove" ]]; to_remove_domain ]]; then
                    local old_nginx_"/var/www/html/nginx_conf_old"/var/log/nginx/conf_avail";log=/etc/nginx/sites-available/
                    local old_nginx_conf_enabled="/etc/nginx/sites-enabled/
                    if [ -f "$old_nginx_conf_available" ] || [ -L "$old_nginx_conf_enabled" ]; then
                        stop_spinner; start_spinner "Xoa cau hinh Nginx cho ${domain_to_remove}..."
                        sudo rm -f "$old_nginx_conf_available"
                        sudo rm -f "$old_nginx_conf_enabled"
                        sudo systemctl reload nginx > /tmp/n8n_reinstall_nginx_reload.log 2>&1
                        stop_spinner; start_spinner "Tiep tuc xoa N8N..."
                    fi

                    stop_spinner; start_spinner "Xoa chung chi SSL cho ${domain_to_remove} (neu co)..."
                    if sudo certbot certificates -d "${domain_to_remove}" 2>/dev/null | grep -q "Certificate Name:"; then
                         local cert_name_to_delete
                         cert_name_to_delete=$(sudo certbot certificates -d "${domain_to_remove}" 2>/dev/null | grep "Certificate Name:" | head -n 1 | awk '{print $3}')
                         if [[ -n "$cert_name_to_delete" ]]; then
                            if ! sudo certbot delete --cert-name "${cert_name_to_delete}" --non-interactive > /tmp/n8n_reinstall_cert_delete.log 2>&1; then
                                stop_spinner
                                echo -e "${RED}Loi khi xoa chung chi SSL. Kiem tra /tmp/n8n_reinstall_cert_delete.log.${NC}"
                            else
                                stop_spinner
                            fi
                         else
                            stop_spinner
                            echo -e "${YELLOW}Khong the xac dinh ten chung chi SSL cho ${domain_to_remove}.${NC}"
                         fi
                    else
                         stop_spinner
                         echo -e "${YELLOW}Khong tim thay chung chi SSL cho ${domain_to_remove} de xoa.${NC}"
                    fi
                    start_spinner "Tiep tuc xoa N8N..."
                else
                     echo -e "\r\033[K ${YELLOW}Khong tim thay ten mien trong ${ENV_FILE}. Bo qua xoa Nginx/SSL.${NC}"
                fi
                
                if [ -d "${NGINX_EXPORT_INCLUDE_DIR}" ]; then
                    stop_spinner; start_spinner "Xoa thu muc cau hinh export Nginx tam thoi..."
                    sudo rm -rf "${NGINX_EXPORT_INCLUDE_DIR}"
                    stop_spinner; start_spinner "Tiep tuc xoa N8N..."
                fi

                stop_spinner
                start_spinner "Xoa thu muc cai dat ${N8N_DIR}..."
                if ! sudo rm -rf "${N8N_DIR}"; then
                    stop_spinner
                    echo -e "${RED}Loi khi xoa thu muc ${N8N_DIR}.${NC}"
                else
                    stop_spinner
                fi
            else
                echo -e "\r\033[K ${YELLOW}Thu muc ${N8N_DIR} khong ton tai. Bo qua buoc xoa.${NC}"
            fi
            
            stop_spinner 
            echo -e "${GREEN}Qua trinh go cai dat va xoa du lieu N8N hoan tat.${NC}"
            echo -e "\n${CYAN}Tien hanh cai dat lai N8N...${NC}"
            
            trap - ERR SIGINT SIGTERM 

            install 
}

# --- Ham Lay thong tin Redis ---
get_redis_info() {
    check_root
    echo -e "\n${CYAN}--- Lay Thong Tin Ket Noi Redis ---${NC}"

    if [ ! -f "${ENV_FILE}" ]; then
        echo -e "${RED}Loi: File cau hinh ${ENV_FILE} khong tim thay.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc (chon muc 1).${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local redis_password
    redis_password=$(grep "^REDIS_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)

    local server_ip=$(get_public_ip)

    if [[ -z "$redis_password" ]]; then
        echo -e "${RED}Loi: Khong tim thay REDIS_PASSWORD trong file ${ENV_FILE}.${NC}"
        echo -e "${YELLOW}File cau hinh co the bi loi hoac Redis chua duoc cau hinh dung.${NC}"
    else
        echo -e "${GREEN}Thong tin ket noi Redis:${NC}"
        echo -e "  ${CYAN}Host:${NC} ${server_ip}"
        echo -e "  ${CYAN}Port:${NC} 6379"
        echo -e "  ${CYAN}User:${NC} default"
        echo -e "  ${CYAN}Password:${NC} ${YELLOW}${redis_password}${NC}"
    fi
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Thay doi ten mien ---
change_domain() {
    check_root
    echo -e "\n${CYAN}--- Thay Doi Ten Mien cho N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local old_domain_name
    old_domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$old_domain_name" ]]; then
        echo -e "${RED}Loi: Khong tim thay DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    echo -e "Ten mien hien tai cua N8N la: ${GREEN}${old_domain_name}${NC}"

    local new_domain_for_change 
    if ! get_domain_and_dns_check_reusable new_domain_for_change "$old_domain_name" "Nhap ten mien MOI ban muon su dung"; then
        read -r -p "Nhan Enter de quay lai menu..." 
        return 0 
    fi
    
    local confirmation_prompt
    confirmation_prompt=$(echo -e "\n${YELLOW}Ban co chac chan muon thay doi ten mien tu ${RED}${old_domain_name}${NC} sang ${GREEN}${new_domain_for_change}${NC} khong?${NC}\n${RED}Hanh dong nay se yeu cau cap lai SSL va khoi dong lai cac service.${NC}\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thay doi ten mien.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh thay doi ten mien (Ma loi: $RC).${NC}"; update_env_file "DOMAIN_NAME" "$old_domain_name"; update_env_file "LETSENCRYPT_EMAIL" "no-reply@${old_domain_name}"; echo -e "${YELLOW}Da khoi phuc ten mien cu trong .env.${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang thay doi ten mien..."

    stop_spinner; start_spinner "Cap nhat file .env voi ten mien moi..."
    if ! update_env_file "DOMAIN_NAME" "$new_domain_for_change"; then
        return 1 
    fi
    if ! update_env_file "LETSENCRYPT_EMAIL" "no-reply@${new_domain_for_change}"; then
        return 1 
    fi
    stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."

    stop_spinner; start_spinner "Dung service N8N..."
    if ! sudo $DOCKER_COMPOSE_CMD -f "${DOCKER_COMPOSE_FILE}" stop ${N8N_SERVICE_NAME} > /tmp/n8n_change_domain_stop.log 2>&1; then
        echo -e "\n${YELLOW}Canh bao: Khong the dung service ${N8N_SERVICE_NAME}. Kiem tra /tmp/n8n_change_domain_stop.log. Tiep tuc voi rui ro.${NC}"
    fi
    stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."

    local old_nginx_conf_avail="/etc/nginx/sites-available/${old_domain_name}.conf"
    local old_nginx_conf_enabled="/etc/nginx/sites-enabled/${old_domain_name}.conf"
    if [ -f "$old_nginx_conf_avail" ] || [ -L "$old_nginx_conf_enabled" ]; then
        stop_spinner; start_spinner "Xoa cau hinh Nginx cu..."
        sudo rm -f "$old_nginx_conf_avail"
        sudo rm -f "$old_nginx_conf_enabled"
        stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."
    fi

    if sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep -q "Certificate Name:"; then
        local old_cert_name
        old_cert_name=$(sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep "Certificate Name:" | head -n 1 | awk '{print $3}')
        if [[ -n "$old_cert_name" ]]; then
            stop_spinner; start_spinner "Xoa chung chi SSL cu (${old_cert_name})..."
            if ! sudo certbot delete --cert-name "${old_cert_name}" --non-interactive > /tmp/n8n_change_domain_cert_delete.log 2>&1; then
                 echo -e "\n${YELLOW}Canh bao: Khong the xoa chung chi SSL cu. Kiem tra /tmp/n8n_change_domain_cert_delete.log.${NC}"
            fi
            stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."
        fi
    fi
    
    stop_spinner 
    if ! create_docker_compose_config; then 
        return 1 
    fi

    if ! configure_nginx_and_ssl; then 
        return 1 
    fi

    start_spinner "Khoi dong lai cac service Docker..." 
    cd "${N8N_DIR}" || { return 1; } 
    
    if ! sudo $DOCKER_COMPOSE_CMD up -d --force-recreate > /tmp/n8n_change_domain_docker_up.log 2>&1; then
        return 1
    fi
    cd - > /dev/null
    stop_spinner

    echo -e "\n${GREEN}Thay doi ten mien thanh cong!${NC}"
    echo -e "N8N hien co the truy cap tai: ${GREEN}https://${new_domain_for_change}${NC}" 
    
    trap - ERR SIGINT SIGTERM 
    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Nang cap phien ban N8N ---
upgrade_n8n_version() {
    check_root
    echo -e "\n${CYAN}--- Nang Cap Phien Ban N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    local current_image_tag="latest" 
    if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        current_image_tag=$(awk '/services:/ {in_services=1} /^  [^ ]/ {if(in_services) in_n8n_service=0} /'${N8N_SERVICE_NAME}':/ {if(in_services) in_n8n_service=1} /image: n8nio\/n8n:/ {if(in_n8n_service) {gsub("n8nio/n8n:", ""); print $2; exit}}' "${DOCKER_COMPOSE_FILE}")
        if [[ -z "$current_image_tag" ]]; then
            current_image_tag="latest (khong xac dinh)"
        fi
    fi
    echo -e "Phien ban N8N hien tai (theo tag image): ${GREEN}${current_image_tag}${NC}"
    echo -e "${YELLOW}Chuc nang nay se nang cap N8N len phien ban '${GREEN}latest${YELLOW}' moi nhat tu Docker Hub.${NC}"
    
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Ban co chac chan muon tiep tuc nang cap khong?\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo nang cap phien ban.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh nang cap (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM
    
    start_spinner "Dang nang cap N8N len phien ban moi nhat..."
    
    cd "${N8N_DIR}" || { return 1; }

    stop_spinner; start_spinner "Dam bao cau hinh Docker Compose su dung tag :latest..."
    if ! create_docker_compose_config; then 
        return 1
    fi
    stop_spinner; start_spinner "Tiep tuc nang cap..."


    run_silent_command "Tai image N8N moi nhat (${N8N_SERVICE_NAME} service)" "$DOCKER_COMPOSE_CMD pull ${N8N_SERVICE_NAME}" "false"
    if [ $? -ne 0 ]; then 
        cd - > /dev/null
        return 1; 
    fi
    
    run_silent_command "Khoi dong lai N8N voi phien ban moi (${N8N_SERVICE_NAME} service)" "$DOCKER_COMPOSE_CMD up -d --force-recreate ${N8N_SERVICE_NAME}" "false"
    if [ $? -ne 0 ]; then 
        cd - > /dev/null
        return 1; 
    fi

    cd - > /dev/null
    stop_spinner

    echo -e "\n${GREEN}Nang cap N8N hoan tat!${NC}"
    echo -e "${YELLOW}N8N da duoc cap nhat len phien ban '${GREEN}latest${YELLOW}' moi nhat.${NC}"
    echo -e "Vui long kiem tra giao dien web cua N8N de xac nhan phien ban."
    
    trap - ERR SIGINT SIGTERM
    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Tat Xac thuc 2 buoc (2FA/MFA) ---
disable_mfa() {
    check_root
    echo -e "\n${CYAN}--- Tat Xac Thuc 2 Buoc (2FA/MFA) cho User N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local user_email
    echo -n -e "Nhap dia chi email cua tai khoan N8N can tat 2FA: "
    read -r user_email

    if [[ -z "$user_email" ]]; then
        echo -e "${RED}Email khong duoc de trong. Huy bo thao tac.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    echo -e "\n${YELLOW}Ban co chac chan muon tat 2FA cho tai khoan voi email ${GREEN}${user_email}${NC} khong?${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Nhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac tat 2FA.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang tat 2FA cho user ${user_email}..."

    local disable_mfa_log="/tmp/n8n_disable_mfa.log"
    local cli_command="docker exec -u node ${N8N_CONTAINER_NAME} n8n umfa:disable --email \"${user_email}\""
    
    if sudo bash -c "${cli_command}" > "${disable_mfa_log}" 2>&1; then
        stop_spinner
        echo -e "\n${GREEN}Lenh tat 2FA da duoc thuc thi.${NC}"
        cat "${disable_mfa_log}" 
        if grep -q -i "disabled MFA for user with email" "${disable_mfa_log}"; then 
            echo -e "${GREEN}2FA da duoc tat thanh cong cho user ${user_email}.${NC}"
        elif grep -q -i "does not exist" "${disable_mfa_log}"; then 
            echo -e "${RED}Loi: Khong tim thay user voi email ${user_email}.${NC}"
        elif grep -q -i "MFA is not enabled" "${disable_mfa_log}"; then
            echo -e "${YELLOW}Thong bao: 2FA chua duoc kich hoat cho user ${user_email}.${NC}"
        else
            echo -e "${YELLOW}Vui long kiem tra output o tren de biet ket qua chi tiet.${NC}"
        fi
    else
        stop_spinner
        echo -e "\n${RED}Loi khi thuc thi lenh tat 2FA.${NC}"
        cat "${disable_mfa_log}"
        echo -e "${YELLOW}Kiem tra log Docker cua container ${N8N_CONTAINER_NAME} de biet them chi tiet.${NC}"
    fi
    sudo rm -f "${disable_mfa_log}"


    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Dat lai thong tin dang nhap ---
reset_user_login() {
    check_root
    echo -e "\n${CYAN}--- Dat Lai Thong Tin Dang Nhap User Owner N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    echo -e "\n${YELLOW}CANH BAO: Hanh dong nay se reset toan bo thong tin tai khoan owner (nguoi dung chu so huu).${NC}"
    echo -e "${YELLOW}Sau khi reset, ban se can phai tao lai tai khoan owner khi truy cap N8N lan dau.${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Ban co chac chan muon tiep tuc?\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac dat lai thong tin dang nhap.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang reset thong tin dang nhap owner..."

    local reset_log="/tmp/n8n_reset_owner.log"
    local cli_command="docker exec -u node ${N8N_CONTAINER_NAME} n8n user-management:reset"

    local cli_exit_code=0
    sudo bash -c "${cli_command}" > "${reset_log}" 2>&1 || cli_exit_code=$?
    
    stop_spinner 

    if [[ $cli_exit_code -eq 0 ]]; then
        echo -e "\n${GREEN}Lenh reset thong tin owner da duoc thuc thi.${NC}"
        echo -e "${CYAN}Output tu lenh:${NC}"
        cat "${reset_log}" 
        
        if grep -q -i "User data for instance owner has been reset" "${reset_log}"; then
             echo -e "${GREEN}Thong tin tai khoan owner da duoc reset thanh cong.${NC}"
             echo -e "${YELLOW}Lan truy cap N8N tiep theo, ban se duoc yeu cau tao lai tai khoan owner.${NC}"
             
             start_spinner "Dang khoi dong lai N8N service..."
             cd "${N8N_DIR}" || { stop_spinner; echo -e "${RED}Khong the truy cap ${N8N_DIR}.${NC}"; return 1; } 
             if ! sudo $DOCKER_COMPOSE_CMD restart ${N8N_SERVICE_NAME} > /tmp/n8n_restart_after_reset.log 2>&1; then
                 stop_spinner
                 echo -e "${RED}Loi khi khoi dong lai N8N service. Kiem tra /tmp/n8n_restart_after_reset.log${NC}"
             else
                 stop_spinner
                 echo -e "${GREEN}N8N service da duoc khoi dong lai.${NC}"
             fi
             cd - > /dev/null
        else
            echo -e "${YELLOW}Reset co the khong thanh cong. Vui long kiem tra output o tren.${NC}"
        fi
    else 
        echo -e "\n${RED}Loi khi thuc thi lenh reset thong tin owner.${NC}"
        echo -e "${YELLOW}Output tu lenh (neu co):${NC}"
        cat "${reset_log}"
        echo -e "${YELLOW}Kiem tra log Docker cua container ${N8N_CONTAINER_NAME} de biet them chi tiet.${NC}"
    fi
    sudo rm -f "${reset_log}"


    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Export Du Lieu ---
export_all_data() {
    check_root
    echo -e "\n${CYAN}--- Export Du Lieu N8N (Workflows & Credentials) ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local domain_name
    domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$domain_name" ]]; then
        echo -e "${RED}Loi: Khong tim thay DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local backup_base_dir="${N8N_DIR}/backups"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local current_backup_dir="${backup_base_dir}/n8n_backup_${timestamp}"
    local container_temp_export_dir="/home/node/.n8n/temp_export_$$" 
    local creds_file="credentials.json"
    local workflows_file="workflows.json"
    local temp_nginx_include_file_path_for_trap="" 

    trap 'RC=$?; stop_spinner; \
        echo -e "\n${YELLOW}Huy bo/Loi trong qua trinh export (Ma loi: $RC). Dang don dep...${NC}"; \
        sudo docker exec -u node ${N8N_CONTAINER_NAME} rm -rf "${container_temp_export_dir}" &>/dev/null; \
        if [ -n "${temp_nginx_include_file_path_for_trap}" ] && [ -f "${temp_nginx_include_file_path_for_trap}" ]; then \
            sudo rm -f "${temp_nginx_include_file_path_for_trap}"; \
            if sudo nginx -t &>/dev/null; then sudo systemctl reload nginx &>/dev/null; fi; \
            echo -e "${YELLOW}Duong dan tai xuong tam thoi da duoc go bo.${NC}"; \
        fi; \
        read -r -p "Nhan Enter de quay lai menu..."; \
        return 0;' ERR SIGINT SIGTERM

    start_spinner "Chuan bi export du lieu..."

    if ! sudo mkdir -p "${current_backup_dir}"; then
        stop_spinner
        echo -e "${RED}Loi: Khong the tao thu muc backup ${current_backup_dir}.${NC}"
        return 1
    fi
    sudo chmod 755 "${current_backup_dir}" 

    if ! sudo docker exec -u node "${N8N_CONTAINER_NAME}" mkdir -p "${container_temp_export_dir}"; then
        stop_spinner
        echo -e "${RED}Loi: Khong the tao thu muc tam trong container N8N.${NC}"
        return 1
    fi
    stop_spinner

    # Export credentials
    local export_creds_log="/tmp/n8n_export_creds.log"
    local export_creds_cmd="n8n export:credentials --all --output=${container_temp_export_dir}/${creds_file}"
    local export_creds_success=false
    
    start_spinner "Dang export credentials..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${export_creds_cmd} > "${export_creds_log}" 2>&1; then
        if sudo docker cp "${N8N_CONTAINER_NAME}:${container_temp_export_dir}/${creds_file}" "${current_backup_dir}/${creds_file}"; then
            export_creds_success=true
            stop_spinner
            echo -e "${GREEN}Export credentials thanh cong: ${current_backup_dir}/${creds_file}${NC}"
        else
            stop_spinner
            echo -e "${RED}Loi: Khong the copy file credentials tu container.${NC}"
            cat "${export_creds_log}"
            return 1
        fi
    else
        stop_spinner
        echo -e "${RED}Loi khi export credentials:${NC}"
        cat "${export_creds_log}"
        return 1
    fi
    sudo rm -f "${export_creds_log}"

    # Export workflows
    local export_workflows_log="/tmp/n8n_export_workflows.log"
    local export_workflows_cmd="n8n export:workflow --all --output=${container_temp_export_dir}/${workflows_file}"
    local export_workflows_success=false
    
    start_spinner "Dang export workflows..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${export_workflows_cmd} > "${export_workflows_log}" 2>&1; then
        if sudo docker cp "${N8N_CONTAINER_NAME}:${container_temp_export_dir}/${workflows_file}" "${current_backup_dir}/${workflows_file}"; then
            export_workflows_success=true
            stop_spinner
            echo -e "${GREEN}Export workflows thanh cong: ${current_backup_dir}/${workflows_file}${NC}"
        else
            stop_spinner
            echo -e "${RED}Loi: Khong the copy file workflows tu container.${NC}"
            cat "${export_workflows_log}"
            return 1
        fi
    else
        stop_spinner
        echo -e "${RED}Loi khi export workflows:${NC}"
        cat "${export_workflows_log}"
        return 1
    fi
    sudo rm -f "${export_workflows_log}"

    # Tao duong dan tai xuong tam thoi qua Nginx
    local temp_download_path="/backup_${timestamp}"
    local temp_nginx_include_file="${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_${timestamp}.conf"
    temp_nginx_include_file_path_for_trap="${temp_nginx_include_file}"

    start_spinner "Tao duong dan tai xuong tam thoi..."
    sudo bash -c "cat > ${temp_nginx_include_file}" <<EOF
location ${temp_download_path}/ {
    alias ${current_backup_dir}/;
    autoindex on;
    allow all;
}
EOF

    if ! sudo nginx -t >/dev/null 2>&1; then
        stop_spinner
        echo -e "${RED}Loi: Cau hinh Nginx khong hop le. Xoa cau hinh tam.${NC}"
        sudo rm -f "${temp_nginx_include_file}"
        temp_nginx_include_file_path_for_trap=""
        return 1
    fi

    sudo systemctl reload nginx >/dev/null 2>&1
    stop_spinner

    echo -e "\n${GREEN}Export du lieu hoan tat!${NC}"
    echo -e "${CYAN}Duong dan tai xuong:${NC} ${GREEN}https://${domain_name}${temp_download_path}/${NC}"
    echo -e "${YELLOW}Luu y: Duong dan nay chi ton tai tam thoi. Vui long tai xuong ngay!${NC}"
    echo -e "${CYAN}Cac file da export:${NC}"
    echo -e "  - Credentials: ${current_backup_dir}/${creds_file}"
    echo -e "  - Workflows: ${current_backup_dir}/${workflows_file}"

   # Don dep thu muc tam trong container
sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_export_dir}"

echo -e "\n${YELLOW}Sau khi tai xuong xong, nhan Enter de xoa duong dan tai xuong tam thoi...${NC}"
read -r

start_spinner "Xoa duong dan tai xuong tam thoi..."
sudo rm -f "${temp_nginx_include_file}"
temp_nginx_include_file_path_for_trap=""
if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx >/dev/null 2>&1
else
    stop_spinner
    echo -e "${RED}Loi: Cau hinh Nginx sau khi xoa khong hop le. Vui long kiem tra /etc/nginx/.${NC}"
    return 1
fi
stop_spinner

echo -e "${GREEN}Da xoa duong dan tai xuong tam thoi.${NC}"
echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
read -r

trap - ERR SIGINT SIGTERM
}

# --- Ham Lap lich sao luu ---
schedule_backup() {
    check_root
    echo -e "\n${CYAN}--- Lap Lich Sao Luu Du Lieu N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    echo -e "${YELLOW}Chuc nang nay se tao mot cong viec cron de sao luu workflows va credentials hang ngay luc 2:00 AM.${NC}"
    echo -e "${CYAN}Cac file sao luu se duoc luu tai: ${N8N_DIR}/backups/YYYYMMDD_HHMMSS/${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Ban co muon tao lich sao luu hang ngay khong?\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac lap lich sao luu.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang thiet lap lich sao luu..."

    local backup_script="${N8N_DIR}/backup_script.sh"
    sudo bash -c "cat > ${backup_script}" <<EOF
#!/bin/bash
BACKUP_DIR="${N8N_DIR}/backups/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\${BACKUP_DIR}"
chmod 755 "\${BACKUP_DIR}"

CONTAINER_TEMP_DIR="/home/node/.n8n/temp_export_\$\$"
docker exec -u node ${N8N_CONTAINER_NAME} mkdir -p "\${CONTAINER_TEMP_DIR}"

docker exec -u node ${N8N_CONTAINER_NAME} n8n export:credentials --all --output="\${CONTAINER_TEMP_DIR}/credentials.json"
docker cp ${N8N_CONTAINER_NAME}:"\${CONTAINER_TEMP_DIR}/credentials.json" "\${BACKUP_DIR}/credentials.json"

docker exec -u node ${N8N_CONTAINER_NAME} n8n export:workflow --all --output="\${CONTAINER_TEMP_DIR}/workflows.json"
docker cp ${N8N_CONTAINER_NAME}:"\${CONTAINER_TEMP_DIR}/workflows.json" "\${BACKUP_DIR}/workflows.json"

docker exec -u node ${N8N_CONTAINER_NAME} rm -rf "\${CONTAINER_TEMP_DIR}"
EOF
    sudo chmod +x "${backup_script}"

    sudo bash -c "cat > ${BACKUP_CRON_FILE}" <<EOF
0 2 * * * root ${backup_script} >> ${N8N_DIR}/backup.log 2>&1
EOF
    sudo chmod 644 "${BACKUP_CRON_FILE}"

    stop_spinner
    echo -e "\n${GREEN}Lap lich sao luu hang ngay da duoc thiet lap!${NC}"
    echo -e "${CYAN}Sao luu se chay luc 2:00 AM moi ngay. Log tai: ${N8N_DIR}/backup.log${NC}"
    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r

    trap - ERR SIGINT SIGTERM
}

# --- Ham Khoi dong lai dich vu ---
restart_services() {
    check_root
    echo -e "\n${CYAN}--- Khoi Dong Lai Dich Vu ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    echo -e "${GREEN}Cac dich vu co the khoi dong lai:${NC}"
    echo -e "  ${YELLOW}1)${NC} N8N"
    echo -e "  ${YELLOW}2)${NC} PostgreSQL"
    echo -e "  ${YELLOW}3)${NC} Redis"
    echo -e "  ${YELLOW}4)${NC} Nginx"
    echo -e "  ${YELLOW}5)${NC} Tat ca dich vu"
    echo -e "  ${YELLOW}0)${NC} Quay lai menu"
    echo -e "\n${CYAN}Nhap lua chon (0-5):${NC} \c"
    read -r service_choice

    case $service_choice in
        0)
            echo -e "\n${GREEN}Quay lai menu chinh...${NC}"
            return 0
            ;;
        1|2|3|5)
            trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM
            start_spinner "Dang khoi dong lai dich vu..."
            cd "${N8N_DIR}" || { stop_spinner; echo -e "${RED}Khong the truy cap ${N8N_DIR}.${NC}"; return 1; }
            case $service_choice in
                1) sudo $DOCKER_COMPOSE_CMD restart ${N8N_SERVICE_NAME} ;;
                2) sudo $DOCKER_COMPOSE_CMD restart postgres ;;
                3) sudo $DOCKER_COMPOSE_CMD restart redis ;;
                5) sudo $DOCKER_COMPOSE_CMD restart && sudo systemctl restart nginx ;;
            esac
            cd - > /dev/null
            stop_spinner
            echo -e "\n${GREEN}Khoi dong lai dich vu thanh cong!${NC}"
            ;;
        4)
            trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM
            start_spinner "Dang khoi dong lai Nginx..."
            sudo systemctl restart nginx
            stop_spinner
            echo -e "\n${GREEN}Khoi dong lai Nginx thanh cong!${NC}"
            ;;
        *)
            echo -e "\n${RED}Lua chon khong hop le. Vui long nhap so tu 0 den 5.${NC}"
            ;;
    esac

    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
    trap - ERR SIGINT SIGTERM
}

# --- Ham Xem log ---
view_logs() {
    check_root
    echo -e "\n${CYAN}--- Xem Log Dich Vu ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local domain_name
    domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$domain_name" ]]; then
        echo -e "${RED}Loi: Khong tim thay DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    echo -e "${GREEN}Cac dich vu co the xem log:${NC}"
    echo -e "  ${YELLOW}1)${NC} N8N"
    echo -e "  ${YELLOW}2)${NC} PostgreSQL"
    echo -e "  ${YELLOW}3)${NC} Redis"
    echo -e "  ${YELLOW}4)${NC} Nginx (access log)"
    echo -e "  ${YELLOW}5)${NC} Nginx (error log)"
    echo -e "  ${YELLOW}0)${NC} Quay lai menu"
    echo -e "\n${CYAN}Nhap lua chon (0-5):${NC} \c"
    read -r log_choice

    case $log_choice in
        0)
            echo -e "\n${GREEN}Quay lai menu chinh...${NC}"
            return 0
            ;;
        1|2|3)
            trap 'RC=$?; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM
            cd "${N8N_DIR}" || { echo -e "${RED}Khong the truy cap ${N8N_DIR}.${NC}"; return 1; }
            case $log_choice in
                1) sudo $DOCKER_COMPOSE_CMD logs --tail=50 ${N8N_SERVICE_NAME} ;;
                2) sudo $DOCKER_COMPOSE_CMD logs --tail=50 postgres ;;
                3) sudo $DOCKER_COMPOSE_CMD logs --tail=50 redis ;;
            esac
            cd - > /dev/null
            ;;
        4|5)
            trap 'RC=$?; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM
            case $log_choice in
                4) sudo tail -n 50 "/var/log/nginx/${domain_name}.access.log" ;;
                5) sudo tail -n 50 "/var/log/nginx/${domain_name}.error.log" ;;
            esac
            ;;
        *)
            echo -e "\n${RED}Lua chon khong hop le. Vui long nhap so tu 0 den 5.${NC}"
            ;;
    esac

    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
    trap - ERR SIGINT SIGTERM
}

# --- Menu Chinh ---
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}===================================================${NC}"
        echo -e "${CYAN}      Quan Ly N8N Cloud By mtdvps.com        ${NC}"
        echo -e "${CYAN}===================================================${NC}\n"
        echo -e "${GREEN}Cac tuy chon quan ly:${NC}"
        echo -e "  ${YELLOW}1)${NC} Cai dat N8N Cloud"
        echo -e "  ${YELLOW}2)${NC} Kiem tra trang thai N8N va he thong"
        echo -e "  ${YELLOW}3)${NC} Lap lich sao luu hang ngay"
        echo -e "  ${YELLOW}4)${NC} Khoi dong lai dich vu"
        echo -e "  ${YELLOW}5)${NC} Xem log dich vu"
        echo -e "  ${YELLOW}6)${NC} Lay thong tin ket noi Redis"
        echo -e "  ${YELLOW}7)${NC} Thay doi ten mien"
        echo -e "  ${YELLOW}8)${NC} Nang cap phien ban N8N"
        echo -e "  ${YELLOW}9)${NC} Tat xac thuc 2 buoc (2FA/MFA) cho user"
        echo -e "  ${YELLOW}10)${NC} Dat lai thong tin dang nhap user owner"
        echo -e "  ${YELLOW}11)${NC} Export tat ca (workflows & credentials)"
        echo -e "  ${YELLOW}12)${NC} Xoa N8N va cai dat lai"
        echo -e "  ${YELLOW}0)${NC} Thoat"
        echo -e "\n${CYAN}Nhap lua chon cua ban (0-12):${NC} \c"
        read -r choice

        case $choice in
            1) install ;;
            2) check_status ;;
            3) schedule_backup ;;
            4) restart_services ;;
            5) view_logs ;;
            6) get_redis_info ;;
            7) change_domain ;;
            8) upgrade_n8n_version ;;
            9) disable_mfa ;;
            10) reset_user_login ;;
            11) export_all_data ;;
            12) reinstall_n8n ;;
            0) echo -e "\n${GREEN}Thoat chuong trinh. Tam biet!${NC}\n"; exit 0 ;;
            *) echo -e "\n${RED}Lua chon khong hop le. Vui long nhap so tu 0 den 12.${NC}"
               echo -e "${YELLOW}Nhan Enter de tiep tuc...${NC}"
               read -r ;;
        esac
    done
}

# --- Ham Chinh ---
main() {
    trap 'echo -e "\n${YELLOW}Chuong trinh bi gian doan. Thoat...${NC}"; exit 1' SIGINT SIGTERM
    main_menu
}

# --- Chay chuong trinh ---
main
