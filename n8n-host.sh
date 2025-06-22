#!/bin/bash

# --- Dinh nghia mau sac ---
RED='\e[1;31m'     # Mau do (dam)
GREEN='\e[1;32m'   # Mau xanh la (dam)
YELLOW='\e[1;33m'  # Mau vang (dam)
CYAN='\e[1;36m'    # Mau xanh cyan (dam)
NC='\e[0m'         # Reset mau (tro ve binh thuong)

# --- Bien Global ---
INSTANCES_BASE_DIR="/n8n-cloud/instances"  # Thư mục chứa các instance n8n
INSTANCE_PREFIX="n8n_instance_"            # Tiền tố cho tên instance
N8N_DIR="/n8n-cloud"                      # Thư mục mặc định cho single instance
ENV_FILE="${N8N_DIR}/.env"
DOCKER_COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose"
SPINNER_PID=0
N8N_CONTAINER_NAME="n8n_app"
N8N_SERVICE_NAME="n8n"
NGINX_EXPORT_INCLUDE_DIR="/etc/nginx/n8n_export_includes"
NGINX_EXPORT_INCLUDE_FILE_BASENAME="n8n_export_location"
TEMPLATE_DIR="/n8n-templates"
TEMPLATE_FILE_NAME="import-workflow-credentials.json"
INSTALL_PATH="/usr/local/bin/n8n-host"

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
  local file="${3:-${ENV_FILE}}"
  if [ ! -f "${file}" ]; then
    echo -e "${RED}Loi: File ${file} khong ton tai. Khong the cap nhat.${NC}"
    return 1
  fi
  if grep -q "^${key}=" "${file}"; then
    sudo sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" | sudo tee -a "${file}" > /dev/null
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
  local prompt_message="${3:-Nhap ten mien ban muon su dung}"

  trap 'echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"; return 1;' SIGINT SIGTERM

  echo -e "${CYAN}---> Nhap thong tin ten mien (Nhan Ctrl+C de huy bo)...${NC}"
  local new_domain_input server_ip resolved_ip

  server_ip=$(get_public_ip)
  if [ $? -ne 0 ]; then
    trap - SIGINT SIGTERM
    return 1
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
  local domain_name_val generic_timezone_val n8n_port_val

  if [ -f "${ENV_FILE}" ]; then
    n8n_encryption_key_val=$(grep "^N8N_ENCRYPTION_KEY=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_user_val=$(grep "^POSTGRES_USER=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_password_val=$(grep "^POSTGRES_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_db_val=$(grep "^POSTGRES_DB=" "${ENV_FILE}" | cut -d'=' -f2)
    redis_password_val=$(grep "^REDIS_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)
    domain_name_val=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    generic_timezone_val=$(grep "^GENERIC_TIMEZONE=" "${ENV_FILE}" | cut -d'=' -f2)
    n8n_port_val=$(grep "^N8N_PORT=" "${ENV_FILE}" | cut -d'=' -f2)
  fi

  sudo bash -c "cat > ${DOCKER_COMPOSE_FILE}" <<EOF
services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: n8n_postgres_${N8N_CONTAINER_NAME##n8n_app_}
    environment:
      - POSTGRES_USER=\${POSTGRES_USER:-${postgres_user_val}}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-${postgres_password_val}}
      - POSTGRES_DB=\${POSTGRES_DB:-${postgres_db_val}}
    volumes:
      - postgres_data_${N8N_CONTAINER_NAME##n8n_app_}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-${postgres_user_val}} -d \${POSTGRES_DB:-${postgres_db_val}}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: always
    container_name: n8n_redis_${N8N_CONTAINER_NAME##n8n_app_}
    command: redis-server --save 60 1 --loglevel warning --requirepass \${REDIS_PASSWORD:-${redis_password_val}}
    ports:
      - "637${N8N_CONTAINER_NAME##n8n_app_}:6379"
    volumes:
      - redis_data_${N8N_CONTAINER_NAME##n8n_app_}:/data
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
      - "127.0.0.1:${n8n_port_val:-5678}:5678"
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
      - n8n_data_${N8N_CONTAINER_NAME##n8n_app_}:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  postgres_data_${N8N_CONTAINER_NAME##n8n_app_}:
  redis_data_${N8N_CONTAINER_NAME##n8n_app_}:
  n8n_data_${N8N_CONTAINER_NAME##n8n_app_}:
EOF
  stop_spinner
}

start_docker_containers() {
  start_spinner "Khoi chay cai dat..."
  cd "${N8N_DIR}" || { return 1; }

  run_silent_command "Tai Docker images" "$DOCKER_COMPOSE_CMD pull" "false"

  run_silent_command "Khoi chay container qua docker-compose" "$DOCKER_COMPOSE_CMD up -d --force-recreate" "false"
  if [ $? -ne 0 ]; then return 1; fi

  sleep 15
  stop_spinner
  echo -e "${GREEN}Cai dat da khoi chay.${NC}"
  cd - > /dev/null
}

configure_nginx_and_ssl() {
  local service_name="$1"
  local domain_name="$2"
  local email="$3"
  local port="$4"

  start_spinner "Cau hinh Nginx va SSL voi Certbot..."
  local webroot_path="/var/www/html"

  local nginx_conf_file="/etc/nginx/sites-available/${domain_name}.conf"

  sudo mkdir -p "${webroot_path}/.well-known/acme-challenge"
  sudo chown www-data:www-data "${webroot_path}" -R

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
        --agree-tos --email "${email}" --non-interactive --quiet \
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

  run_silent_command "Tao cau hinh Nginx cuoi cung voi SSL va proxy" \
  "bash -c \"cat > ${nginx_conf_file}\" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }

 subtitle $"1$" {
        return 301 $"https://\\$host\\$request_uri$";
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain_name};

    ssl_certificate /etc/letsencrypt/live/${domain_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain_name}/privkey.pem;

    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparams /etc/letsencrypt/ssl-dhparams.pem;

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }

    include ${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_${service_name}_*.conf;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    client_max_body_size 100M;

    access_log /var/log/nginx/${domain_name}.access.log;
    error_log /var/log/nginx/${domain_name}.error.log;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \\$host;
        proxy_set_header X-Real-IP \\$remote_addr;
        proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \\$http_upgrade;
        proxy_set_header Connection 'upgrade";

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

  if [ ! -f "${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_${service_name}.conf" ]; then
    sudo touch "${NGINX_EXPORT_INCLUDE_DIR}/${service_name}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_${service_name}.conf"
  fi

  run_silent_command "Kiem tra cau hinh Nginx cuoi cung" "nginx -t" "false" || return 1

  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo systemctl list-timers | grep -q 'certbot.timer'; then
    sudo systemctl enable certbot.timer >/dev/null 2>&1
    sudo systemctl start certbot.timer >/dev/null 2>&1
  fi
  run_silent_command "Kiem tra gia han SSL" "certbot renew --dry-run" "false"

  stop_spinner
  echo -e "${GREEN}Cau hinh Nginx va SSL hoan tat.${NC}.$NC$"
}
final_checks_and_message() {
  start_spinner "Thuc hien kiem tra cuoi cung..."
  local domain_name
  domain_name=$(grep - "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)

  sleep 10

  local http_status=$(curl -L -s -o /dev/null -w "%{http_code}" "https://${domain_name}")
  stop_spinner

  if [[ "$http_status" == "200" ]]; then
    echo -e "${GREEN}Cai dat thanh cong!${NC}"
    echo -e "Ban co the truy cap tai: ${GREEN}https://${domain_name}${NC}"
  else
    echo -e "${RED}Loi: Khong the truy cap tai https://${domain_name} (HTTP Status Code: ${http_status}).${NC}"
    echo -e "${YELLOW}Vui long kiem tra cac buoc sau:${NC}"
    echo -e "  1. Log Docker cua container: sudo ${DOCKER_COMPOSE_TOP} -f ${DOCKER_COMPOSE_FILE} logs ${N8N_CONTAINER_NAME}"
    echo -e "  2. Log Nginx: sudo tail -n 50 /var/log/nginx/${domain_name}.error.log"
    echo -e "  3. Trang thai Certbot: sudo certbot certificates"
    echo -e "  4. Dam bao DNS da tro dung va khong co firewall nao chan port 80/443."
    return 1
  fi

  echo -e "${YELLOW}Quan trong: Hay luu tru file ${ENV_FILE} o mot noi an toan!${NC}"
  echo -e "Ban nen tao user dau tien ngay sau khi truy cap."
}

# --- Ham chinh de Cai dat N8N (Single Instance) ---
install_single_n8n() {
  check_root
  if [ -d "${N8N_DIR}" ] && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    echo -e "\n${YELLOW}[CANH BAO] Phat hien thu muc ${N8N_DIR} va file ${DOCKER_COMPOSE_FILE} da ton tai.${NC}"
    local existing_containers
    if command_exists $DOCKER_COMPOSE_TOP && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
      pushd "${N8n_DIR}" > /dev/null || { echo -e "${RED}Khong the truy cap thu muc ${N8N_DIR}${NC}"; return 1; fi
      existing_containers=$(sudo $DOCKER_COMPOSE_COMPOSE_CMD ps -q 2>/dev/null)
      popd > /dev/null
    fi

    if [[ -n "$existing_containers" ]] || [ -f "${DOCKER_COMPOSE_FILE}" ]; then
      echo -e "${YELLOW}    Co ve nhu N8N da duoc cai dat hoac da co mot phan cau hinh truoc do.${NC}"; 
      echo -e "${YELLOW}    Neu ban muon cai dat lai, vui long chon muc '10) Xoa N8N va cai dat lai'.${NC}"
      echo -e "${YELLOW}    Nhan Enter de quay lai menu chinh...${NC}"
      read -r
      return 0
    fi
  fi

  echo -e "\n${CYAN}===================================================\n${NC}"
  echo -e "${CYAN}         Bat dau qua trinh cai dat N8N Cloud       ${NC}"
  echo -e "${CYAN}===================================================${NC}\n"

  trap 'RC=$?; stop_scanner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh cai dat (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

  install_prerequisites
  setup_directories_and_env_file

  local domain_name_for_install
  if ! get_domain_and_dns_check_reusable_domain_name_for_install "" "Nhap ten mien ban muon su dung cho N8N"; then
    return 0
  fi
  update_env_file "DOMAIN_NAME" "$domain_name_for_install"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name_for_install}"
  update_env_file "N8N_PORT" "5678"

  generate_credentials
  create_docker_compose_config
  start_docker_containers
  configure_nginx_and_ssl n8n "${domain_name_for_install}" "no-reply@${domain_name_for_install}" "5678"
  final_checks_and_message

  trap - ERR SIGINT SIGTERM

  echo -e "\n${GREEN}===================================================${NC}"
  echo -e "${GREEN}      Hoan tat qua trinh cai dat N8N Cloud!       ${NC}"
  echo -e "${GREEN}===================================================${NC}\n"
  echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
  read -r
}

# --- Ham tao nhieu instance N8N ---
create_multiple_n8n_instances() {
  check_root
  echo -e "\n${CYAN}--- Tạo Nhiều Instance N8N ---${NC}"

  local num_instances
  echo -n -e "${YELLOW}Nhập số lượng instance n8n muốn tạo (1-10): ${NC}"
  read -r num_instances

  if ! [[ "$num_instances" =~ ^[1-9]$|^10$ ]]; then
    echo -e "${RED}Số lượng không hợp lệ. Vui lòng nhập từ 1 đến 10.${NC}"
    read -r -p "Nhấn Enter để quay lại menu..."
    return 0
  fi

  trap 'stop_spinner; echo -e "\n${RED}Đã xảy ra lỗi hoặc hủy bỏ trong quá trình tạo instance.${NC}"; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

  sudo mkdir -p "${INSTANCES_BASE_DIR}"
  local instance_count=1

  while [ $instance_count -le $num_instances ]; do
    echo -e "\n${CYAN}--- Cấu hình instance n8n thứ $instance_count ---${NC}"
    local instance_name="${INSTANCE_PREFIX}${instance_count}"
    local instance_dir="${INSTANCES_BASE_DIR}/${instance_name}"
    local instance_env_file="${instance_dir}/.env"
    local instance_compose_file="${instance_dir}/docker-compose.yml"
    local instance_port=$((5678 + instance_count - 1))

    # Gán lại biến toàn cục
    N8N_DIR="${instance_dir}"
    ENV_FILE="${instance_env_file}"
    DOCKER_COMPOSE_FILE="${instance_compose_file}"
    N8N_CONTAINER_NAME="n8n_app_${instance_count}"
    N8N_SERVICE_NAME="n8n_${instance_count}"
    NGINX_EXPORT_INCLUDE_DIR="/etc/nginx/n8n_export_includes/${instance_name}"

    setup_directories_and_env_file

    local domain_name
    if ! get_domain_and_dns_check_reusable domain_name "" "Nhập tên miền cho instance n8n thứ $instance_count"; then
      echo -e "${YELLOW}Hủy cấu hình instance thứ $instance_count.${NC}"
      continue
    fi
    update_env_file "DOMAIN_NAME" "$domain_name"
    update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name}"
    update_env_file "N8N_PORT" "${instance_port}"

    generate_credentials
    create_docker_compose_config
    start_docker_containers
    configure_nginx_and_ssl n8n "${domain_name}" "no-reply@${domain_name}" "${instance_port}"
    final_checks_and_message

    echo -e "${GREEN}Instance n8n thứ $instance_count đã được tạo thành công tại ${domain_name}!${NC}"
    instance_count=$((instance_count + 1))
  done

  trap - ERR SIGINT SIGTERM
  echo -e "\n${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
  read -r
}

# --- Ham cai dat NocoDB ---
install_nocodb() {
  echo -e "\n${CYAN}--- Cài đặt NocoDB ---${NC}"
  trap 'stop_spinner; echo -e "\n${RED}Lỗi hoặc hủy bỏ khi cài đặt NocoDB.${NC}"; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

  local nocodb_dir="/nocodb"
  local env_file="${nocodb_dir}/.env"
  local compose_file="${nocodb_dir}/docker-compose.yml"
  local domain_name

  if ! get_domain_and_dns_check_reusable domain_name "" "Nhập tên miền cho NocoDB"; then
    return 0
  fi

  start_spinner "Thiết lập thư mục và file cấu hình..."
  sudo mkdir -p "${nocodb_dir}"
  sudo touch "${env_file}"
  sudo chmod 600 "${env_file}"
  update_env_file "DOMAIN_NAME" "$domain_name" "${env_file}"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name}" "${env_file}"
  update_env_file "NC_DB" "postgres://nocodb_user:$(generate_random_string 32)@postgres/nocodb_db?sslmode=disable" "${env_file}"

  sudo bash -c "cat > ${compose_file}" <<EOF
services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: nocodb_db
    environment:
      - POSTGRES_USER=nocodb_user
      - POSTGRES_PASSWORD=\${NC_DB##*@postgres/}
      - POSTGRES_DB=nocodb_db
    volumes:
      - nocodb_postgres_data:/var/lib/postgresql/data

  nocodb:
    image: nocodb/nocodb:latest
    restart: always
    container_name: nocodb_app
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - NC_DB=\${NC_DB}
    depends_on:
      - postgres
    volumes:
      - nocodb_data:/usr/app/data

volumes:
  nocodb_postgres_data:
  nocodb_data:
EOF

  stop_spinner
  start_spinner "Khởi chạy NocoDB..."
  cd "${nocodb_dir}" || return 1
  run_silent_command "Tải image Docker" "$DOCKER_COMPOSE_CMD pull" "false"
  run_silent_command "Khởi chạy container" "$DOCKER_COMPOSE_CMD up -d" "false"
  cd - > /dev/null

  start_spinner "Cấu hình Nginx và SSL..."
  configure_nginx_and_ssl nocodb "${domain_name}" "no-reply@${domain_name}" "8080"

  stop_spinner
  echo -e "${GREEN}Cài đặt NocoDB hoàn thành! Truy cập tại: https://${domain_name}${NC}"
  read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Ham cai dat Baserow ---
install_baserow() {
  echo -e "\n${CYAN}--- Cài đặt Baserow ---${NC}"
  trap 'stop_spinner; echo -e "\n${RED}Lỗi hoặc hủy bỏ khi cài đặt Baserow.${NC}"; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

  local baserow_dir="/baserow"
  local env_file="${baserow_dir}/.env"
  local compose_file="${baserow_dir}/docker-compose.yml"
  local domain_name

  if ! get_domain_and_dns_check_reusable domain_name "" "Nhập tên miền cho Baserow"; then
    return 0
  fi

  start_spinner "Thiết lập thư mục và file cấu hình..."
  sudo mkdir -p "${baserow_dir}"
  sudo touch "${env_file}"
  sudo chmod 600 "${env_file}"
  update_env_file "DOMAIN_NAME" "$domain_name" "${env_file}"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name}" "${env_file}"
  update_env_file "BASEROW_PUBLIC_URL" "https://${domain_name}" "${env_file}"
  update_env_file "POSTGRES_PASSWORD" "$(generate_random_string 32)" "${env_file}"

  sudo bash -c "cat > ${compose_file}" <<EOF
services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: baserow_db
    environment:
      - POSTGRES_USER=baserow
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=baserow
    volumes:
      - baserow_postgres_data:/var/lib/postgresql/data

  baserow:
    image: baserow/baserow:latest
    restart: always
    container_name: baserow_app
    ports:
      - "127.0.0.1:80:80"
    environment:
      - BASEROW_PUBLIC_URL=\${BASEROW_PUBLIC_URL}
      - DATABASE_HOST=postgres
      - DATABASE_USER=baserow
      - DATABASE_PASSWORD=\${POSTGRES_PASSWORD}
      - DATABASE_NAME=baserow
    depends_on:
      - postgres
    volumes:
      - baserow_data:/baserow/data

volumes:
  baserow_postgres_data:
  baserow_data:
EOF

  stop_spinner
  start_spinner "Khởi chạy Baserow..."
  cd "${baserow_dir}" || return 1
  run_silent_command "Tải image Docker" "$DOCKER_COMPOSE_CMD pull" "false"
  run_silent_command "Khởi chạy container" "$DOCKER_COMPOSE_CMD up -d" "false"
  cd - > /dev/null

  start_spinner "Cấu hình Nginx và SSL..."
  configure_nginx_and_ssl baserow "${domain_name}" "no-reply@${domain_name}" "80"

  stop_spinner
  echo -e "${GREEN}Cài đặt Baserow hoàn thành! Truy cập tại: https://${domain_name}${NC}"
  read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Ham cai dat Supabase ---
install_supabase() {
  echo -e "\n${CYAN}--- Cài đặt Supabase ---${NC}"
  trap 'stop_spinner; echo -e "\n${RED}Lỗi hoặc hủy bỏ khi cài đặt Supabase.${NC}"; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

  local supabase_dir="/supabase"
  local env_file="${supabase_dir}/.env"
  local compose_file="$supabase_dir/docker-compose.yml"
  local domain_name

  if ! get_domain_and_dns_check_reusable domain_name "" "Nhập tên miền cho Supabase"; then
    return 0
  fi

  start_spinner "Thiết lập thư mục và file cấu hình..."
  sudo mkdir -p "${supabase_dir}"
  sudo touch "${env_file}"
  sudo chmod 600 "${env_file}"
  update_env_file "DOMAIN_NAME" "$domain_name" "${env_file}"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name}" "${env_file}"
  update_env_file "POSTGRES_PASSWORD" "$(generate_random_string 32)" "${env_file}"
  update_env_file "JWT_SECRET" "$(generate_random_string 64)" "${env_file}"
  update_env_file "ANON_KEY" "$(generate_random_string 64)" "${env_file}"
  update_env_file "SERVICE_KEY" "$(generate_random_string 64)" "${env_file}"

  sudo bash -c "cat > ${compose_file}" <<EOF
services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: supabase_db
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=postgres
    volumes:
      - supabase_postgres_data:/var/lib/postgresql/data

  supabase_studio:
    image: supabase/studio:latest
    restart: always
    container_name: supabase_studio
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      - SUPABASE_URL=https://${domain_name}
      - SUPABASE_ANON_KEY=\${ANON_KEY}
      - SUPABASE_SERVICE_KEY=\${SERVICE_KEY}

  rest:
    image: postgrest/postgrest:latest
    restart: always
    container_name: supabase_rest
    environment:
      - PGRST_DB_URI=postgres://authenticator:\${POSTGRES_PASSWORD}@postgres:5432/postgres
      - PGRST_DB_SCHEMA=public
      - PGRST_JWT_SECRET=\${JWT_SECRET}
    depends_on:
      - postgres

  realtime:
    image: supabase/realtime:latest
    restart: always
    container_name: supabase_realtime
    environment:
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_NAME=postgres
      - DB_USER=authenticator
      - DB_PASSWORD=\${POSTGRES_PASSWORD}
      - JWT_SECRET=\${JWT_SECRET}
    depends_on:
      - postgres

volumes:
  supabase_postgres_data:
EOF

  stop_spinner
  start_spinner "Khởi chạy Supabase..."
  cd "${supabase_dir}" || return 1
  run_silent_command "Tải image Docker" "$DOCKER_COMPOSE_CMD pull" "false"
  run_silent_command "Khởi chạy container" "$DOCKER_COMPOSE_CMD up -d" "false"
  cd - > /dev/null

  start_spinner "Cấu hình Nginx và SSL..."
  configure_nginx_and_ssl supabase "${domain_name}" "no-reply@${domain_name}" "3000"

  stop_spinner
  echo -e "${GREEN}Cài đặt Supabase hoàn thành! Truy cập Studio tại: https://${domain_name}${NC}"
  echo -e "Anon Key: $(grep "^ANON_KEY=" "${env_file}" | cut -d'=' -f2)"
  echo -e "Service Key: $(grep "^SERVICE_KEY=" "${env_file}" | cut -d'=' -f2)"
  read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Ham cai dat cac dich vu bo sung ---
install_additional_services() {
  check_root
  echo -e "\n${CYAN}--- Cài đặt Dịch vụ Bổ sung (NocoDB/Baserow/Supabase) ---${NC}"

  echo -e "Chọn dịch vụ muốn cài đặt:"
  echo -e "  ${GREEN}1)${NC} NocoDB"
  echo -e "  ${GREEN}2)${NC} Baserow"
  echo -e "  ${GREEN}3)${NC} Supabase"
  echo -e "  ${YELLOW}0)${NC} Quay lại menu chính"
  read -p "$(echo -e ${CYAN}'Nhập lựa chọn (0-3): '${NC})" service_choice

  case "$service_choice" in
    1) install_nocodb ;;
    2) install_baserow ;;
    3) install_supabase ;;
    0) return 0 ;;
    *)
    echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
    read -r -p "Nhấn Enter để quay lại..."
    return 0
    ;;
  esac
}

# --- Ham Xoa N8N va Cai dat lai ---
reinstall_n8n() {
  check_root
  echo -e "\n${RED}======================= CANH BAO XOA DU LIEU =======================${NC}"
  echo -e "${YELLOW}Ban da chon chuc nang XOA TOAN BO N8N va CAI DAT LAI.${NC}"
  echo -e "${RED}HANH DONG NAY SE XOA VINH VIEN:${NC}"
  echo -e "${RED}  - Toan bo du lieu n8n (workflows, credentials, executions,...).${NC}"
  echo -e "${RED}  - Database PostgreSQL cua n8n.${NC}"
  echo -e "${RED}  - Du lieu cache Redis (neu co).${NC}"
  echo -e "${RED}  - Cau hinh Nginx va SSL cho ten mien hien tai cua n8n.${NC}"
  echo -e "${RED}  - Toan bo thu muc cai dat ${N8N_DIR}.${NC}"
  echo -e "\n${YELLOW}DE NGHI: Neu ban co du lieu quan trong, hay su dung chuc nang${NC}"
  echo -e "${YELLOW}  '6) Export tat ca (workflow & credentials)'${NC}"
  echo -e "${YELLOW}de SAO LUU du lieu truoc khi tiep tuc.${NC}"

  local confirm_prompt
  confirm_prompt=$(echo -e "${YELLOW}Nhap '${NC}${RED}delete${NC}${YELLOW}' de xac nhan xoa, hoac nhap '${NC}${CYAN}0${NC}${YELLOW}' de quay lai menu: ${NC}")
  echo -n "$confirm_prompt"
  read -r confirmation

  if [[ "$confirmation" == "0" ]]; then
    echo -e "\n${GREEN}Huy bo thao tac. Quay lai menu chinh...${NC}"
    sleep 1
    return 0
  elif [[ "$confirmation" != "delete" ]]; then
    echo -e "\n${RED}Xac nhan khong hop le. Huy bo thao tac.${NC}"
    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh..."
    read -r
    return 0
  fi

  echo -e "\n${CYAN}Bat dau qua trinh xoa N8N...${NC}"
  trap - 'stop_scanner; echo -e "\n${RED}Da xay ra loi hoac huy bo trong qua trinh xoa N8n.${NC}"; read -r -p "Nhan Enter de quay lai menu..."; return 0; fi"; ERR SIGINT SIGTERM

  start_docker_spinner "Dang xoa N8n..."

  if [ -d "${N8N_DIR}" ]; then
    if [ -f "${DOCKER_COMPOSITE_FILE}" ]; then
      stop_docker_spinner
      start_docker
      pushd "${push_d}${N8N_DIR}" > /dev/null_dev/null || || { echo -e "${RED}Loi${NC}"; error: cannot access ${NC}8${NC}"; return 1; fi }
      if ! sudo -c $DOCKER_CONF_COMPOSE_CONF ps down -v --n-remove-orphans > /tmp >/tmp/nvm_reinstall_docker_reinstall_down.log 2>&1; then
        error_stop_docker
        echo -e "${RED}Loi khi dừng/xóa Docker. Kiem tra /tmp/n_reinstall_docker_down.log.${NC}"
      fi fi
      popd > /dev/null_dev
      stop_docker_docker
      start_docker_docker "Tiep tuc xoa N8n..."
    else
      echo -e "\r\033[K ${YELLOW}Khong tim thay file ${DOCKER_CONF_FILE}}. ${NC}"
      echo "${YELLOW} Bỏ qua bước xóa Docker.${NC}"    fi

    local domain_to_remove
    if [ -f "${ENV_FILE}" ]]; then
      domain_to_remove=$(grep - "^${DOMAIN_NAME}"="${ENV_FILE}" "${NC}" | cut -d'=' -f2)
    fi

    if [[ -n "$domain_to_remove" ]]; then
      local nginx_conf_remove="/etc/nginx/sites-available/${domain_to_remove}/*.conf"
      local nginx_conf_enabled="/etc/nginx/sites-enabled/${domain_to_remove}/*.conf"

      if [[ -f "$nginx_conf_remove" ]] || [[ -f "$nginx_conf_enabled" ]]; then
        error_stop_docker
        start_docker "Xóa cấu hình Nginx cho ${domain_to_remove}..."
        sudo rm -f -r "$nginx_conf_remove"
        sudo rm -f -r "${nginx_conf_enabled}"
        sudo systemctl restart nginx > /tmp/n_reinstall_nginx_reload.log 2>&1
        stop_docker_docker
        start_docker_docker "Tiep tuc xoa N8N..."
      fi

      stop_docker_docker
      start_docker_docker "Xoa chung chi SSL cho ${server_to_remove} (neu co)..."
      if sudo certbot ls -d "${server_ip_to_remove}" 2>/dev/null | grep -q "Certificate Name"; then
        local cert_name_to_remove
        cert_name_to_remove=$(sudo ls -d "${server_ip_to_remove}" 2>&1 | grep -A "Certificate Name" | head -n 1 | awk '{print $3}')
        if [[ -n "$cert_name_to_remove" ]]; then
          if ! sudo -c certbot delete ---cert-name "${cert_name_to_remove}" ---non-interactive > /tmp/n_reinstall_cert_delete.log 2>&1; then
            error_stop_docker
            echo -e "${RED} error when deleting SSL certificate: ${/tmp/n_reinstall_cert_delete.log}.${NC}"
          else
            error_stop_docker
          fi
        else
          error_stop_docker
          echo -e "${YELLOW} error: could not identify SSL certificate name for ${server_ip_to_remove}.${NC}"
        fi
      else
        echo -e "${YELLOW} warning: no SSL certificate found to delete for ${server_ip}.${NC}"
      fi
      start_docker_docker "Tiep tuc xoa N8N..."
    else
      echo - "\r\n\033[K ${YELLOW} warning: domain not found in ${ENV_FILE}}. ${NC} Skipping Nginx/SSL deletion.${NC}"
    fi

    if [ -d "${NGINX_EXPORT_EXCLUDE_DIR}" ]; then
      stop_docker_docker; start_docker_docker "Xoa thu muc cau hinh export Nginx tam thoi..."
      sudo rm -rf -r "${NGINX_EXPORT_EXCLUDE_DIR}"
      stop_docker_docker; start_docker_docker "Tiep tuc xoa N8N..."
    fi

    stop_docker_docker
    start_docker_docker "Xoa thu muc cai dat ${N8N_DIR}..."
    if ! sudo rm -rf -r "${N8N_DIR}"; then
      error_stop_docker
      echo -e "${RED} error deleting directory ${N8N_DIR}.${NC}"
    else
      error_stop_docker
    fi
  else
    echo -e "\r\033[K ${YELLOW} warning: directory ${N8N_DIR} does not exist. Skipping deletion step.${NC}"
  fi

  error_stop_docker
  echo -e "${GREEN}Qua trinh go cai dat va xoa du lieu N8N hoan tat.${NC}"
  echo -e "\n${CYAN}Tien hanh cai dat lai N8N...${NC}"

  trap - ERR SIGINT SIGTERM

  install_single_n8n
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
  local old_nginx_conf_avail="/etc/nginx/sites-available/${old_domain_name}.conf"
  local old_nginx_conf_enabled="/etc/nginx/sites-enabled/${old_domain_name}.conf"
  if [ -f "$old_nginx_conf_avail" ] || [ -L "$old_nginx_conf_enabled" ]; then
    stop_spinner; start_spinner "Xoa cau hinh Nginx cu..."
    sudo rm -f "$old_nginx_conf_avail"
    sudo rm -f "${old_nginx_conf_enabled}"
    stop_d fi

  if sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep -q "Certificate Name"; then
    local old_cert_name certificates
    old_cert=$name $(sudo certificates -d "${old_domain_name}" -2>/dev/null | grep -A "Certificate Name:" | head -n 1 | awk '{print $3}')
    if [ -n "$old_cert_name" ]; then
      stop_docker; start_docker "Xoa chung chi SSL cu (${old_domain_name})..."
      if ! sudo certbot delete ---cert_name "${old_cert_name}" ---non_interactive > /tmp/n_change_domain_cert_delete.log 2>&1; then
        echo -e "\n${YELLOW}Canh bao: Khong the xoa chung chi SSL cu. Kiem tra /tmp/n_change_domain_cert_delete.log ${NC}"
      fi
      stop_docker_docker; start_docker_docker "Tiep tuc thay doi ten dien..."
    fi
  fi

  stop_docker
  if ! create_docker_compose_config; then
    return 1
  fi

  if ! configure_nginx_and_ssl_and_ssl n8n "${new_domain_for_change}" "no-reply@${new_domain_for_change}" "$(grep "^${N8N_PORT}"="${ENV_FILE}" | cut -d'=' -f2)"; then
    return 1
  fi

  start_docker_da "Khoi dong lai cac service Docker..."
  cd "${current_N8N_DIR}" || "${N8N_DIR}" || { return 1; fi
}

 1
  fi
}

  cd - > /dev/null_dev
  stop_docker_docker

  echo - "${GREEN}Thay doi ten dien thanh cong!${NC}"
  echo - "${GREEN}N8N hien co the truy cap tai: https://${new_domain_for_change}${NC}"

  ${

  trap - ERR - SIGTERM SIGTERM
  echo - "${YELLOW}Nhan Enter de quay lai menu chinh..."
  read -r -r
}
