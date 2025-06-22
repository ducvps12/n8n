#!/bin/bash

# --- Định nghĩa màu sắc ---
RED='\e[1;31m'     # Màu đỏ (đậm)
GREEN='\e[1;32m'   # Màu xanh lá (đậm)
YELLOW='\e[1;33m'  # Màu vàng (đậm)
CYAN='\e[1;36m'    # Màu xanh cyan (đậm)
NC='\e[0m'         # Reset màu (trở về bình thường)

# --- Biến Global ---
INSTANCES_DIR="/n8n-instances" # Thư mục chứa các instance n8n
INSTANCE_NAME="" # Tên instance hiện tại
N8N_DIR="/n8n-cloud" # Thư mục mặc định (sẽ được ghi đè khi chọn instance)
ENV_FILE="${N8N_DIR}/.env"
DOCKER_COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose"
SPINNER_PID=0
N8N_CONTAINER_NAME="n8n_app"
N8N_SERVICE_NAME="n8n"
NGINX_EXPORT_INCLUDE_DIR="/etc/nginx/n8n_export_includes"
NGINX_EXPORT_INCLUDE_FILE_BASENAME="n8n_export_location"
TEMPLATE_DIR="/n8n-templates" # Thư mục chứa template trên host
TEMPLATE_FILE_NAME="import-workflow-credentials.json" # Tên file template
INSTALL_PATH="/usr/local/bin/n8n-host" # Đường dẫn cài đặt script

# --- Hàm Kiểm tra ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "\n${RED}[!] Lỗi: Bạn cần chạy script với quyền Quản trị viên (root).${NC}\n"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_package_installed() {
  dpkg -s "$1" &> /dev/null
}

# --- Hàm Phụ trợ ---
get_public_ip() {
  local ip
  ip=$(curl -s --ipv4 https://ifconfig.co) || \
  ip=$(curl -s --ipv4 https://api.ipify.org) || \
  ip=$(curl -s --ipv4 https://icanhazip.com) || \
  ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
  if [[ -z "$ip" ]]; then
    echo -e "${RED}[!] Không thể lấy địa chỉ IP public của server.${NC}"
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
  local env_file="${3:-$ENV_FILE}"
  if [ ! -f "${env_file}" ]; then
    echo -e "${RED}Lỗi: File ${env_file} không tồn tại. Không thể cập nhật.${NC}"
    return 1
  fi
  if grep -q "^${key}=" "${env_file}"; then
    sudo sed -i "s|^${key}=.*|${key}=${value}|" "${env_file}"
  else
    echo "${key}=${value}" | sudo tee -a "${env_file}" > /dev/null
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
      echo -e "\n${RED}Lỗi trong khi [${message}] (xử lý ngầm).${NC}"
      echo -e "${RED}Chi tiết lỗi đã được ghi vào: ${log_file}${NC}"
      echo -e "${RED}5 dòng cuối của log:${NC}"
      tail -n 5 "${log_file}" | sed 's/^/    /'
      return 1
    fi
  else
    local spinner_was_globally_running=false
    if [[ $SPINNER_PID -ne 0 ]]; then
        spinner_was_globally_running=true
        stop_spinner
    fi

    echo -n -e "${CYAN}Xử lý: ${message}... ${NC}"

    if sudo bash -c "${command_to_run}" > "${log_file}" 2>&1; then
      echo -e "${GREEN}Xong.${NC}"
      sudo rm -f "${log_file}"
      return 0
    else
      echo -e "${RED}Thất bại.${NC}"
      echo -e "${RED}Chi tiết lỗi đã được ghi vào: ${log_file}${NC}"
      echo -e "${RED}5 dòng cuối của log:${NC}"
      tail -n 5 "${log_file}" | sed 's/^/    /'
      return 1
    fi
  fi
}

# --- Các bước Cài đặt ---

install_prerequisites() {
  start_spinner "Kiểm tra và cài đặt các gói phụ thuộc..."

  run_silent_command "Cập nhật danh sách gói" "apt-get update -y" "false"
  if [ $? -ne 0 ]; then return 1; fi

  if ! is_package_installed nginx; then
    run_silent_command "Cài đặt Nginx" "apt-get install -y nginx" "false"
    if [ $? -ne 0 ]; then return 1; fi
    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl start nginx >/dev/null 2>&1
  fi

  if ! command_exists docker; then
    if ! curl -fsSL https://get.docker.com -o get-docker.sh; then
        echo -e "${RED}Lỗi tải script cài đặt Docker.${NC}"
        return 1
    fi
    run_silent_command "Cài đặt Docker từ script" "sh get-docker.sh" "false"
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
    run_silent_command "Tải Docker Compose v${LATEST_COMPOSE_VERSION}" \
      "curl -L \"https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose" "false"
    if [ $? -ne 0 ]; then return 1; fi
    sudo chmod +x /usr/local/bin/docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
  fi

  if ! command_exists certbot; then
    run_silent_command "Cài đặt Certbot và plugin Nginx" "apt-get install -y certbot python3-certbot-nginx" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if ! command_exists dig; then
    run_silent_command "Cài đặt dnsutils (cho dig)" "apt-get install -y dnsutils" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if ! command_exists curl; then
    run_silent_command "Cài đặt curl" "apt-get install -y curl" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if command_exists ufw; then
    sudo ufw allow http > /dev/null
    sudo ufw allow https > /dev/null
  fi

  stop_spinner
  echo -e "${GREEN}Kiểm tra và cài đặt gói phụ thuộc hoàn tất.${NC}"
}

setup_directories_and_env_file() {
  start_spinner "Thiết lập thư mục và file .env..."
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
  echo -e "${GREEN}Thiết lập thư mục và file .env hoàn tất.${NC}"
}

get_domain_and_dns_check_reusable() {
  local result_var_name="$1"
  local current_domain_to_avoid="${2:-}"
  local prompt_message="${3:-Nhập tên miền bạn muốn sử dụng (ví dụ: n8n.example.com)}"

  trap 'echo -e "\n${YELLOW}Hủy bỏ nhập tên miền.${NC}"; return 1;' SIGINT

  echo -e "${CYAN}---> Nhập thông tin tên miền (Nhấn Ctrl+C để hủy)...${NC}"
  local new_domain_input
  local server_ip
 local resolved_ip

  server_ip=$(get_public_ip)
  if [ $? -ne 0 ]; then
    trap - SIGINT
    return 0;
  fi

  echo -e "Địa chỉ IP công cộng của server là: ${GREEN}${server_ip}${NC}"

  while true; do
    local prompt_string
    prompt_string=$(echo -e "${prompt_message}: ")
    echo -n "$prompt_string"

    if ! read -r new_domain_input; then
        echo -e "\n${YELLOW}Hủy bỏ nhập tên miền.${NC}"
        trap - SIGINT
        return 1
    fi

    if [[ -z "$new_domain_input" ]]; then
      echo -e "${RED}Tên miền không được để trống. Vui lòng nhập lại.${NC}"
      continue
    if [[ -n "$current_domain_to_avoid" && "$new_domain_input" == "$current_domain_to_avoid" ]]; then
      echo -e "${YELLOW}Tên miền mới (${new_domain_input}) trùng với tên miền hiện tại (${current_domain_to_avoid}).${NC}"
      echo -e "${YELLOW}Vui lòng nhập một tên miền khác.${NC}"
      continue
    fi

    start_spinner "Kiểm tra DNS cho ${new_domain_input}..."
    resolved_ip=$(timeout 5 dig +short A "$new_domain_input" @1.1.1.1 | tail -n1)
    if [[ -z "$resolved_ip" ]]; then
        local cname_target
        cname_target=$(timeout 5 dig +short CNAME "$new_domain_input" @1.1.1.1 | tail -n1)
        if [[ -n "$cname_target" ]]; then
             resolved_ip=$(timeout 5 dig +short A "${cname_target}" @1.1.1.1 | tail -n1)
        fi
    fi
    stop_spinner

    if [[ "$resolved_ip" == "$server_ip" ]]; then
      echo -e "${GREEN}DNS cho ${new_domain_input} đã được trỏ về IP server chính xác (${resolved_ip}).${NC}"
      printf -v "$result_var_name" "%s" "$new_domain_input"
      trap - SIGINT
      break
    else
      echo -e "${RED}Lỗi: Tên miền ${new_domain_input} (trỏ về ${resolved_ip:-'không tìm thấy bản ghi A/CNAME hoặc timeout'}) chưa được trỏ về IP server (${server_ip}).${NC}"
      echo -e "${YELLOW}Vui lòng trỏ DNS A record của ${new_domain_input} về địa chỉ IP ${server_ip} và đợi DNS cập nhật.${NC}"

      trap 'echo -e "\n${YELLOW}Hủy bỏ nhập tên miềnn...${NC}"; return 1;' SIGINT

      local choice_prompt
      choice_prompt=$(echo -e "${CYAN}Nhấn Enter để kiểm tra lại, hoặc '${CYAN}s${NC}' để bỏ qua, '${CYAN}0${NC}' để hủy bỏ: ${NC}")
      echo -n "$choice_prompt"
      if ! read -r dns_choice; then
          echo -e "\n${YELLOW}Hủy bỏ nhập lựa chọn.${NC}"
          trap - SIGINT
          return 1
      fi

      if [[ "$dns_choice" == "s" || "$dns_choice" == "S" ]]; then
        echo -e "${YELLOW}Bỏ qua kiểm tra DNS. Đảm bảo bạn đã trỏ DNS chính xác.${NC}"
        printf -v "$result_var_name" "%s" "$new_domain_input"
        trap - SIGINT
        break
      elif [[ "$dns_choice" == "0" ]]; then
        echo -e "${YELLOW}Hủy bỏ nhập tên miền.${NC}"
        trap - SIGINT
        return 1
      fi
    fi
  done
  trap - SIGINT
  return 0
}

generate_credentials() {
  start_spinner "Tạo thông tin đăng nhập và cấu hình..."
  update_env_file "N8N_ENCRYPTION_KEY" "$(generate_random_string 64)"
  local system_timezone
  system_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null)
  update_env_file "GENERIC_TIMEZONE" "${system_timezone:-Asia/Ho_Chi_Minh}"

  update_env_file "POSTGRES_DB" "n8n_db_$(generate_random_string 6 | tr '[:upper:]' '[:lower:]')"
  update_env_file "POSTGRES_USER" "n8n_user_$(generate_random_string 8 | tr '[:upper:]' '[:lower:]')"
  update_env_file "POSTGRES_PASSWORD" "$(generate_random_string 32)"

  update_env_file "REDIS_PASSWORD" "$(generate_random_string 32)"

  stop_spinner
  echo -e "${GREEN}Thông tin đăng nhập và cấu hình đã được lưu vào ${ENV_FILE}.${NC}"
  echo -e "${YELLOW}Quan trọng: Vui lòng sao lưu file ${ENV_FILE}.${NC}"
}

create_docker_compose_config() {
  start_spinner "Tạo file docker-compose.yml cho instance ${INSTANCE_NAME}..."
  local n8n_encryption_key_val postgres_user_val postgres_password_val postgres_db_val redis_password_val
  local domain_name_val generic_timezone_val
  local n8n_port=$((5678 + $(echo -n "${INSTANCE_NAME}" | cksum | awk '{print $1 % 1000}')))
  
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
services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: n8n_postgres_${INSTANCE_NAME}
    environment:
      - POSTGRES_USER=\${POSTGRES_USER:-${postgres_user_val}}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-${postgres_password_val}}
      - POSTGRES_DB=\${POSTGRES_DB:-${postgres_db_val}}
    volumes:
      - postgres_data_${INSTANCE_NAME}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-${postgres_user_val}} -d \${POSTGRES_DB:-${postgres_db_val}}"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7}
    restart: always
    container_name: n8n_redis_${INSTANCE_NAME}
    command: redis-server --save 60 1 --loglevel warning --requirepass \${REDIS_PASSWORD:-${redis_password_val}}
    ports:
      - "6379:6379"
    volumes:
      - redis_data_${INSTANCE_NAME}:/data
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
      - "127.0.0.1:${n8n_port}:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB:-${postgres_db_val}}
      - DB_POSTGRESDB_USER=${POSTGRES_USER:-${postgres_user_val}}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD:-${postgres_password_val}}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY:-${n8n_encryption_key_val}}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-${generic_timezone_val}}
      - N8N_HOST=${DOMAIN_NAME:-${domain_name_val}}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://\${DOMAIN_NAME:-${domain_name_val}}/
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_BASIC_AUTH_ACTIVE=false
      - N8N_RUNNERS_ENABLED=true
    volumes:
      - n8n_data_${INSTANCE_NAME}:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  postgres_data_${INSTANCE_NAME}:
  redis_data_${INSTANCE_NAME}:
  n8n_data_${INSTANCE_NAME}:
EOF
  stop_spinner
}

start_docker_containers() {
  start_spinner "Khởi chạy cài đặt N8N Cloud cho instance ${INSTANCE_NAME}..."
  cd "${N8N_DIR}" || { return 1; }

  run_silent_command "Tải Docker images" "$DOCKER_COMPOSE_CMD pull" "false"

  run_silent_command "Khởi chạy container qua docker-compose" "$DOCKER_COMPOSE_CMD up -d --force-recreate" "false"
  if [ $? -ne 0 ]; then return 1; fi

  sleep 15
  stop_spinner
  echo -e "${GREEN}N8N Cloud cho instance ${INSTANCE_NAME} đã khởi chạy.${NC}"
  cd - > /dev/null
}

configure_nginx_and_ssl() {
  start_spinner "Cấu hình Nginx và SSL cho instance ${INSTANCE_NAME}..."
  local domain_name
  local user_email
  domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
  user_email=$(grep "^LETSENCRYPT_EMAIL=" "${ENV_FILE}" | cut -d'=' -f2)
  local webroot_path="/var/www/html"
  local n8n_port=$((5678 + $(echo -n "${INSTANCE_NAME}" | cksum | awk '{print $1 % 1000}')))

  if [[ -z "$domain_name" || -z "$user_email" ]]; then
    echo -e "${RED}Không tìm thấy DOMAIN_NAME hoặc LETSENCRYPT_EMAIL trong file ${ENV_FILE}.${NC}"
    return 1
  fi

  local nginx_conf_file="/etc/nginx/sites-available/${domain_name}.conf"

  sudo mkdir -p "${webroot_path}/.well-known/acme-challenge"
  sudo chown www-data:www-data "${webroot_path}" -R

  run_silent_command "Tạo cấu hình Nginx ban đầu cho HTTP challenge" \
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

  run_silent_command "Kiểm tra cấu hình Nginx HTTP" "nginx -t" "false" || return 1

  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo certbot certonly --webroot -w "${webroot_path}" -d "${domain_name}" \
        --agree-tos --email "${user_email}" --non-interactive --quiet \
        --preferred-challenges http --force-renewal > /tmp/certbot_obtain.log 2>&1; then
    echo -e "${RED}Lấy chứng chỉ SSL thất bại.${NC}"
    echo -e "${YELLOW}Kiểm tra log Certbot tại /var/log/letsencrypt/ và /tmp/certbot_obtain.log.${NC}"
    return 1
  fi

  sudo mkdir -p /etc/letsencrypt
  if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
    run_silent_command "Tải tùy chọn SSL của Let's Encrypt" \
    "curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf" "false" || return 1
fi

  if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
    run_silent_command "Tạo tham số SSL DH" "openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048" "false" || return 1
  fi

  run_silent_command "Tạo cấu hình Nginx cuối cùng với SSL và proxy" \
  "bash -c \"cat > ${nginx_conf_file}\" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
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
        proxy_pass http://127.0.0.1:${n8n_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
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

  if [ ! -f "${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}.conf" ]; then
    sudo touch "${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}.conf"
  fi

  run_silent_command "Kiểm tra cấu hình Nginx cuối cùng" "nginx -t" "false" || return 1

  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo systemctl list-timers | grep -q 'certbot.timer'; then
      sudo systemctl enable certbot.timer >/dev/null 2>&1
      sudo systemctl start certbot.timer >/dev/null 2>&1
  fi
  run_silent_command "Kiểm tra gia hạn SSL" "certbot renew --dry-run" "false"

  stop_spinner
  echo -e "${GREEN}Cấu hình Nginx và SSL hoàn tất.${NC}"
}

final_checks_and_message() {
  start_spinner "Thực hiện kiểm tra cuối cùng..."
  local domain_name
  domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)

  sleep 10

  local http_status
  http_status=$(curl -L -s -o /dev/null -w "%{http_code}" "https://${domain_name}")

  stop_spinner

  if [[ "$http_status" == "200" ]]; then
    echo -e "${GREEN}N8N Cloud cho instance ${INSTANCE_NAME} đã được cài đặt thành công!${NC}"
    echo -e "Bạn có thể truy cập n8n tại: ${GREEN}https://${domain_name}${NC}"
  else
    echo -e "${RED}Lỗi! Không thể truy cập n8n tại https://${domain_name} (HTTP Status Code: ${http_status}).${NC}"
    echo -e "${YELLOW}Vui lòng kiểm tra các bước sau:${NC}"
    echo -e "  1. Log Docker của container n8n: sudo ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE} logs ${N8N_CONTAINER_NAME}"
    echo -e "  2. Log Nginx: sudo tail -n 50 /var/log/nginx/${domain_name}.error.log (hoặc access.log)"
    echo -e "  3. Trạng thái Certbot: sudo certbot certificates"
    echo -e "  4. Đảm bảo DNS đã trỏ đúng và không có firewall nào chặn port 80/443."
    return 1
  fi

  echo -e "${YELLOW}Quan trọng: Hãy lưu trữ file ${ENV_FILE} ở một nơi an toàn!${NC}"
  echo -e "Bạn nên tạo user đầu tiên cho n8n ngay sau khi truy cập."
}

# --- Hàm chính để Cài đặt N8N ---
install() {
  check_root
  if [[ -z "$INSTANCE_NAME" ]]; then
    echo -e "${YELLOW}Vui lòng chọn hoặc tạo một instance trước (tùy chọn 11 hoặc 12).${NC}"
    read -r -p "Nhấn Enter để quay lại menu..."
    return 0
  fi

  if [ -d "${N8N_DIR}" ] && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    echo -e "\n${YELLOW}[CẢNH BÁO] Phát hiện thư mục ${N8N_DIR} và file ${DOCKER_COMPOSE_FILE} đã tồn tại cho instance ${INSTANCE_NAME}.${NC}"
    local existing_containers
    if command_exists $DOCKER_COMPOSE_CMD && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        pushd "${N8N_DIR}" > /dev/null || { echo -e "${RED}Không thể truy cập thư mục ${N8N_DIR}${NC}"; return 1; }
        existing_containers=$(sudo $DOCKER_COMPOSE_CMD ps -q 2>/dev/null)
        popd > /dev/null
    fi
    if [[ -n "$existing_containers" ]] || [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} đã được cài đặt hoặc có cấu hình trước đó.${NC}"
        echo -e "${YELLOW}Vui lòng chọn '10) Xóa N8N và cài đặt lại' để xóa instance này hoặc tạo instance mới.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi
  fi

  echo -e "\n${CYAN}===================================================${NC}"
  echo -e "${CYAN}         Bắt đầu cài đặt instance ${INSTANCE_NAME}        ${NC}"
  echo -e "${CYAN}===================================================${NC}\n"

  trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Lỗi trong quá trình cài đặt (Mã lỗi: $RC).${NC}"; fi; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

  install_prerequisites
  setup_directories_and_env_file
  local domain_name_for_install
  if ! get_domain_and_dns_check_reusable domain_name_for_install "" "Nhập tên miền cho instance ${INSTANCE_NAME}"; then
    return 0
  fi
  update_env_file "DOMAIN_NAME" "$domain_name_for_install"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name_for_install}"
  generate_credentials
  create_docker_compose_config
  start_docker_containers
  configure_nginx_and_ssl
  final_checks_and_message

  trap - ERR SIGINT SIGTERM
  echo -e "\n${GREEN}===================================================${NC}"
  echo -e "${GREEN}      Hoàn tất cài đặt instance ${INSTANCE_NAME}!       ${NC}"
  echo -e "${GREEN}===================================================${NC}\n"
  read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Hàm Xóa N8N và Cài đặt lại ---
reinstall_n8n() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${RED}======================= CẢNH BÁO XÓA DỮ LIỆU =======================${NC}"
    echo -e "${YELLOW}Bạn đã chọn chức năng XÓA TOÀN BỘ instance ${INSTANCE_NAME} và CÀI ĐẶT LẠI.${NC}"
    echo -e "${RED}HÀNH ĐỘNG NÀY SẼ XÓA VĨNH VIỄN:${NC}"
    echo -e "${RED}  - Toàn bộ dữ liệu n8n (workflows, credentials, executions,...).${NC}"
    echo -e "${RED}  - Database PostgreSQL của instance ${INSTANCE_NAME}.${NC}"
    echo -e "${RED}  - Dữ liệu cache Redis (nếu có).${NC}"
    echo -e "${RED}  - Cấu hình Nginx và SSL cho tên miền hiện tại của instance.${NC}"
    echo -e "${RED}  - Toàn bộ thư mục cài đặt ${N8N_DIR}.${NC}"
    echo -e "\n${YELLOW}ĐỀ NGHỊ: Nếu bạn có dữ liệu quan trọng, hãy sử dụng chức năng${NC}"
    echo -e "${YELLOW}  '7) Export tất cả (workflow & credentials)'${NC}"
    echo -e "${YELLOW}để SAO LƯU dữ liệu trước khi tiếp tục.${NC}"
    echo -e "${RED}Hành động này KHÔNG THE HOÀN TÁC.${NC}"

    local confirm_prompt
    confirm_prompt=$(echo -e "${YELLOW}Nhập '${NC}${RED}delete${NC}${YELLOW}' để xác nhận xóa, hoặc nhập '${NC}${CYAN}0${NC}${YELLOW}' để quay lại menu: ${NC}")
    local confirmation
    echo -n "$confirm_prompt"
    read -r confirmation

    if [[ "$confirmation" == "0" ]]; then
        echo -e "\n${GREEN}Hủy bỏ thao tác. Quay lại menu chính...${NC}"
        sleep 1
        return 0
    elif [[ "$confirmation" != "delete" ]]; then
        echo -e "\n${RED}Xác nhận không hợp lệ. Hủy bỏ thao tác.${NC}"
        echo -e "${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
        read -r
        return 0
    fi

    echo -e "\n${CYAN}Bắt đầu quá trình xóa instance ${INSTANCE_NAME}...${NC}"
    trap 'RC=$?; stop_spinner; echo -e "\n${RED}Đã xảy ra lỗi hoặc hủy bỏ trong quá trình xóa instance ${INSTANCE_NAME}.${NC}"; read -r -p "Nhấn Enter để tiếp tục..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang xóa instance ${INSTANCE_NAME}..."

    if [ -d "${N8N_DIR}" ]; then
        if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
            stop_spinner
            start_spinner "Đang tiến hành xóa dữ liệu..."
            pushd "${N8N_DIR}" > /dev/null || { stop_spinner; echo -e "${RED}Lỗi: Không thể truy cập ${N8N_DIR}.${NC}"; return 1; }
            if ! sudo $DOCKER_COMPOSE_CMD down -v --remove-orphans > /tmp/n8n_reinstall_docker_down.log 2>&1; then
                stop_spinner
                echo -e "${RED}Lỗi khi dừng/xóa Docker. Kiểm tra /tmp/n8n_reinstall_docker_down.log.${NC}"
            fi
            popd
            stop_spinner
            start_spinner "Tiếp tục xóa instance ${INSTANCE_NAME}..."
        else
            echo -e "\r\033[K ${YELLOW}Không tìm thấy file ${DOCKER_COMPOSE_FILE}. Bỏ qua bước xóa Docker.${NC}"
        fi

        local domain_to_remove
        if [ -f "${ENV_FILE}" ]; then
            domain_to_remove=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
        fi

        if [[ -n "$domain_to_remove" ]]; then
            local nginx_conf_avail="/etc/nginx/sites-available/${domain_to_remove}.conf"
            local nginx_conf_enabled="/etc/nginx/sites-enabled/${domain_to_remove}.conf"

            if [ -f "$nginx_conf_avail" ] || [ -L "$nginx_conf_enabled" ]; then
                 stop_spinner
                 start_spinner "Xóa cấu hình Nginx cho ${domain_to_remove}..."
                 sudo rm -f "$nginx_conf_avail"
                 sudo rm -f "$nginx_conf_enabled"
                 sudo systemctl reload nginx > /tmp/n8n_reinstall_nginx_reload.log 2>&1
                 stop_spinner
                 start_spinner "Tiếp tục xóa instance ${INSTANCE_NAME}..."
            fi

            stop_spinner
            start_spinner "Xóa chứng chỉ SSL cho ${domain_to_remove} (nếu có)..."
            if sudo certbot certificates -d "${domain_to_remove}" 2>/dev/null | grep -q "Certificate Name:"; then
                 local cert_name_to_delete
                 cert_name_to_delete=$(sudo certbot certificates -d "${domain_to_remove}" 2>/dev/null | grep "Certificate Name:" | head -n 1 | awk '{print $3}')
                 if [[ -n "$cert_name_to_delete" ]]; then
                    if ! sudo certbot delete --cert-name "${cert_name_to_delete}" --non-interactive > /tmp/n8n_reinstall_cert_delete.log 2>&1; then
                        stop_spinner
                        echo -e "${RED}Lỗi khiếu xóa chứng chỉ SSL. Kiểm tra /tmp/n8n_reinstall_cert_delete.log.${NC}"
                    else
                        stop_spinner
                    fi
                 else
                    stop_spinner
                    echo -e "${YELLOW}Không thể xác định tên chứng chỉ SSL cho ${domain_to_remove}.${NC}"
                 fi
            else
                 stop_spinner
                 echo -e "${YELLOW}Không tìm thấy chứng chỉ SSL cho ${domain_to_remove} để xóa.${NC}"
            fi
            start_spinner "Tiếp tục xóa instance ${INSTANCE_NAME}..."
        else
             echo -e "\r\033[K ${YELLOW}Không tìm thấy tên miền trong ${ENV_FILE}. Bỏ qua xóa Nginx/SSL.${NC}"
        fi

        if [ -d "${NGINX_EXPORT_INCLUDE_DIR}" ]; then
            stop_spinner; start_spinner "Xóa thư mục cấu hình export Nginx tạm thời..."
            sudo rm -rf "${NGINX_EXPORT_INCLUDE_DIR}"
            stop_spinner; start_spinner "Tiếp tục xóa instance ${INSTANCE_NAME}..."
        fi

        stop_spinner
        start_spinner "Xóa thư mục cài đặt ${N8N_DIR}..."
        if ! sudo rm -rf "${N8N_DIR}"; then
            stop_spinner
            echo -e "${RED}Lỗi khi xóa thư mục ${N8N_DIR}.${NC}"
            return 1
        else
            stop_spinner
        fi
    else
        echo -e "\r\033[K ${YELLOW}Thư mục ${N8N_DIR} không tồn tại. Bỏ qua bước xóa...${NC}"
    fi

    stop_spinner
    echo -e "${GREEN}Quá trình gỡ cài đặt và xóa dữ liệu instance ${INSTANCE_NAME} hoàn tất.${NC}"
    echo -e "\n${CYAN}Tiến hành cài đặt lại instance ${INSTANCE_NAME}...${NC}"

    trap - ERR SIGINT

    install
}

# --- Hàm Lấy thông tin Redis ---
get_redis_info() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${CYAN}--- Lấy Thông Tin Kết Nối Redis cho instance ${INSTANCE_NAME} ---${NC}"

    if [ ! -f "${ENV_FILE}" ]; then
        echo -e "${RED}Lỗi: File cấu hình ${ENV_FILE} không tìm thấy.${NC}"
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} chưa được cài đặt. Vui lòng cài đặt trước.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local redis_password
    redis_password=$(grep "^REDIS_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)

    local server_ip=$(get_public_ip)

    if [[ -z "$redis_password" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy REDIS_PASSWORD trong file ${ENV_FILE}.${NC}"
        echo -e "${YELLOW}File cấu hình có thể bị lỗi hoặc Redis chưa được cấu hình đúng.${NC}"
    else
        echo -e "${GREEN}Thông tin kết nối Redis:${NC}"
        echo -e "  ${CYAN}Host:${NC} ${server_ip}"
        echo -e "  ${CYAN}Port:${NC} 6379"
        echo -e "  ${CYAN}User:${NC} default"
        echo -e "  ${CYAN}Password:${NC} ${YELLOW}${redis_password}${NC}"
    fi
    echo -e "\n${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Thay đổi tên miền ---
change_domain() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${CYAN}--- Thay Đổi Tên Miền cho instance ${INSTANCE_NAME} ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy file cấu hình ${ENV_FILE} hoặc ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} chưa được cài đặt. Vui lòng cài đặt trước.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local old_domain_name
    old_domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$old_domain_name" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi
    echo -e "Tên miền hiện tại của instance ${INSTANCE_NAME} là: ${GREEN}${old_domain_name}${NC}"

    local new_domain_for_change
    if ! get_domain_and_dns_check_reusable new_domain_for_change "$old_domain_name" "Nhập tên miền MỚI cho instance ${INSTANCE_NAME}"; then
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local confirmation_prompt
    confirmation_prompt=$(echo -e "\n${YELLOW}Bạn có chắc chắn muốn thay đổi tên miền từ ${RED}${old_domain_name}${NC} sang ${GREEN}${new_domain_for_change}${NC} không?${NC}\n${RED}Hành động này sẽ yêu cầu cấp lại SSL và khởi động lại các service.${NC}\nNhập '${GREEN}ok${NC}' để xác nhận, hoặc bất kỳ phím nào khác để hủy bỏ: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Hủy bỏ thay đổi tên miền.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Đã xảy ra lỗi trong quá trình thay đổi tên miền (Mã lỗi: $RC).${NC}"; update_env_file "DOMAIN_NAME" "$old_domain_name"; update_env_file "LETSENCRYPT_EMAIL" "no-reply@${old_domain_name}"; echo -e "${YELLOW}Đã khôi phục tên miền cũ trong .env.${NC}"; fi; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang thay đổi tên miền..."

    stop_spinner; start_spinner "Cập nhật file .env với tên miền mới..."
    if ! update_env_file "DOMAIN_NAME" "$new_domain_for_change"; then
        return 1
    fi
    if ! update_env_file "LETSENCRYPT_EMAIL" "no-reply@${new_domain_for_change}"; then
        return 1
    fi
    stop_spinner; start_spinner "Tiếp tục thay đổi tên miền..."

    stop_spinner; start_spinner "Dừng service ${N8N_SERVICE_NAME}..."
    if ! sudo $DOCKER_COMPOSE_CMD -f "${DOCKER_COMPOSE_FILE}" stop ${N8N_SERVICE_NAME} > /tmp/n8n_change_domain_stop.log 2>&1; then
        echo -e "\n${YELLOW}Cảnh báo: Không thể dừng service ${N8N_SERVICE_NAME}. Kiểm tra /tmp/n8n_change_domain_stop.log. Tiếp tục với rủi ro.${NC}"
    fi
    stop_spinner; start_spinner "Tiếp tục thay đổi tên miền..."

    local old_nginx_conf_avail="/etc/nginx/sites-available/${old_domain_name}.conf"
    local old_nginx_conf_enabled="/etc/nginx/sites-enabled/${old_domain_name}.conf"
    if [ -f "$old_nginx_conf_avail" ] || [ -L "$old_nginx_conf_enabled" ]; then
        stop_spinner; start_spinner "Xóa cấu hình Nginx cũ..."
        sudo rm -f "$old_nginx_conf_avail"
        sudo rm -f "$old_nginx_conf_enabled"
        stop_spinner; start_spinner "Tiếp tục thay đổi tên miền..."
    fi

    if sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep -q "Certificate Name:"; then
        local old_cert_name
        old_cert_name=$(sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep "Certificate Name:" | head -n 1 | awk '{print $3}')
        if [[ -n "$old_cert_name" ]]; then
            stop_spinner; start_spinner "Xóa chứng chỉ SSL cũ (${old_cert_name})..."
            if ! sudo certbot delete --cert-name "${old_cert_name}" --non-interactive > /tmp/n8n_change_domain_cert_delete.log 2>&1; then
                 echo -e "\n${YELLOW}Cảnh báo: Không thể xóa chứng chỉ SSL cũ. Kiểm tra /tmp/n8n_change_domain_cert_delete.log.${NC}"
            fi
            stop_spinner; start_spinner "Tiếp tục thay đổi tên miền..."
        fi
    fi

    stop_spinner
    if ! create_docker_compose_config; then
        return 1
    fi

    if ! configure_nginx_and_ssl; then
        return 1
    fi

    start_spinner "Khởi động lại các service Docker..."
    cd "${N8N_DIR}" || { return 1; }

    if ! sudo $DOCKER_COMPOSE_CMD up -d --force-recreate > /tmp/n8n_change_domain_docker_up.log 2>&1; then
        return 1
    fi
    cd - > /dev/null
    stop_spinner

    echo -e "\n${GREEN}Thay đổi tên miền thành công!${NC}"
    echo -e "Instance ${INSTANCE_NAME} hiện có thể truy cập tại: ${GREEN}https://${new_domain_for_change}${NC}"

    trap - ERR SIGINT SIGTERM
    echo -e "${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Nâng cấp phiên bản N8N ---
upgrade_n8n_version() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${CYAN}--- Nâng Cấp Phiên Bản N8N cho instance ${INSTANCE_NAME} ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy file cấu hình ${ENV_FILE} hoặc ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} chưa được cài đặt. Vui lòng cài đặt trước.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local current_image_tag="latest"
    if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        current_image_tag=$(awk '/services:/ {in_services=1} /^  [^ ]/ {if(in_services) in_n8n_service=0} /'${N8N_SERVICE_NAME}':/ {if(in_services) in_n8n_service=1} /image: n8nio\/n8n:/ {if(in_n8n_service) {gsub("n8nio/n8n:", ""); print $2; exit}}' "${DOCKER_COMPOSE_FILE}")
        if [[ -z "$current_image_tag" ]]; then
            current_image_tag="latest (không xác định)"
        fi
    fi
    echo -e "Phiên bản N8N hiện tại (theo tag image): ${GREEN}${current_image_tag}${NC}"
    echo -e "${YELLOW}Chức năng này sẽ nâng cấp N8N lên phiên bản '${GREEN}latest${YELLOW}' mới nhất từ Docker Hub.${NC}"

    local confirmation_prompt
    confirmation_prompt=$(echo -e "Bạn có chắc chắn muốn tiếp tục nâng cấp không?\nNhập '${GREEN}ok${NC}' để xác nhận, hoặc bất kỳ phím nào khác để hủy bỏ: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Hủy bỏ nâng cấp phiên bản.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Đã xảy ra lỗi trong quá trình nâng cấp (Mã lỗi: $RC).${NC}"; fi; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang nâng cấp N8N lên phiên bản mới nhất..."

    cd "${N8N_DIR}" || { return 1; }

    stop_spinner; start_spinner "Đảm bảo cấu hình Docker Compose sử dụng tag :latest..."
    if ! create_docker_compose_config; then
        return 1
    fi
    stop_spinner; start_spinner "Tiếp tục nâng cấp..."

    run_silent_command "Tải image N8N mới nhất (${N8N_SERVICE_NAME} service)" "$DOCKER_COMPOSE_CMD pull ${N8N_SERVICE_NAME}" "false"
    if [ $? -ne 0 ]; then
        cd - > /dev/null
        return 1;
    fi

    run_silent_command "Khởi động lại N8N với phiên bản mới (${N8N_SERVICE_NAME} service)" "$DOCKER_COMPOSE_CMD up -d --force-recreate ${N8N_SERVICE_NAME}" "false"
    if [ $? -ne 0 ]; then
        cd - > /dev/null
        return 1;
    fi

    cd - > /dev/null
    stop_spinner

    echo -e "\n${GREEN}Nâng cấp N8N hoàn tất!${NC}"
    echo -e "${YELLOW}N8N đã được cập nhật lên phiên bản '${GREEN}latest${YELLOW}' mới nhất.${NC}"
    echo -e "Vui lòng kiểm tra giao diện web của N8N để xác nhận phiên bản."

    trap - ERR SIGINT SIGTERM
    echo -e "${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Tắt Xác thực 2 bước (2FA/MFA) ---
disable_mfa() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${CYAN}--- Tắt Xác Thực 2 Bước (2FA/MFA) cho User N8N instance ${INSTANCE_NAME} ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy file cấu hình ${ENV_FILE} hoặc ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} chưa được cài đặt. Vui lòng cài đặt trước.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local user_email
    echo -n -e "Nhập địa chỉ email của tài khoản N8N cần tắt 2FA: "
    read -r user_email

    if [[ -z "$user_email" ]]; then
        echo -e "${RED}Email không được để trống. Hủy bỏ thao tác.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    echo -e "\n${YELLOW}Bạn có chắc chắn muốn tắt 2FA cho tài khoản với email ${GREEN}${user_email}${NC} không?${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Nhập '${GREEN}ok${NC}' để xác nhận, hoặc bất kỳ phím nào khác để hủy bỏ: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Hủy bỏ thao tác tắt 2FA.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Đã xảy ra lỗi (Mã lỗi: $RC).${NC}"; fi; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang tắt 2FA cho user ${user_email}..."

    local disable_mfa_log="/tmp/n8n_disable_mfa.log"
    local cli_command="docker exec -u node ${N8N_CONTAINER_NAME} n8n umfa:disable --email \"${user_email}\""

    if sudo bash -c "${cli_command}" > "${disable_mfa_log}" 2>&1; then
        stop_spinner
        echo -e "\n${GREEN}Lệnh tắt 2FA đã được thực thi.${NC}"
        cat "${disable_mfa_log}"
        if grep -q -i "disabled MFA for user with email" "${disable_mfa_log}"; then
            echo -e "${GREEN}2FA đã được tắt thành công cho user ${user_email}.${NC}"
        elif grep -q -i "does not exist" "${disable_mfa_log}"; then
            echo -e "${RED}Lỗi: Không tìm thấy user với email ${user_email}.${NC}"
        elif grep -q -i "MFA is not enabled" "${disable_mfa_log}"; then
            echo -e "${YELLOW}Thông báo: 2FA chưa được kích hoạt cho user ${user_email}.${NC}"
        else
            echo -e "${YELLOW}Vui lòng kiểm tra output ở trên để biết kết quả chi tiết.${NC}"
        fi
    else
        stop_spinner
        echo -e "\n${RED}Lỗi khi thực thi lệnh tắt 2FA.${NC}"
        cat "${disable_mfa_log}"
        echo -e "${YELLOW}Kiểm tra log Docker của container ${N8N_CONTAINER_NAME} để biết thêm chi tiết.${NC}"
    fi
    sudo rm -f "${disable_mfa_log}"

    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Đặt lại thông tin đăng nhập ---
reset_user_login() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${CYAN}--- Đặt Lại Thông Tin Đăng Nhập User Owner N8N instance ${INSTANCE_NAME} ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy file cấu hình ${ENV_FILE} hoặc ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} chưa được cài đặt. Vui lòng cài đặt trước.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    echo -e "\n${YELLOW}CẢNH BÁO: Hành động này sẽ reset toàn bộ thông tin tài khoản owner (người dùng chủ sở hữu).${NC}"
    echo -e "${YELLOW}Sau khi reset, bạn sẽ cần phải tạo lại tài khoản owner khi truy cập N8N lần đầu.${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Bạn có chắc chắn muốn tiếp tục?\nNhập '${GREEN}ok${NC}' để xác nhận, hoặc bất kỳ phím nào khác để hủy bỏ: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Hủy bỏ thao tác đặt lại thông tin đăng nhập.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Đã xảy ra lỗi (Mã lỗi: $RC).${NC}"; fi; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang reset thông tin đăng nhập owner..."

    local reset_log="/tmp/n8n_reset_owner.log"
    local cli_command="docker exec -u node ${N8N_CONTAINER_NAME} n8n user-management:reset"

    local cli_exit_code=0
    sudo bash -c "${cli_command}" > "${reset_log}" 2>&1 || cli_exit_code=$?

    stop_spinner

    if [[ $cli_exit_code -eq 0 ]]; then
        echo -e "\n${GREEN}Lệnh reset thông tin owner đã được thực thi.${NC}"
        echo -e "${CYAN}Output từ lệnh:${NC}"
        cat "${reset_log}"

        if grep -q -i "User data for instance owner has been reset" "${reset_log}"; then
             echo -e "${GREEN}Thông tin tài khoản owner đã được reset thành công.${NC}"
             echo -e "${YELLOW}Lần truy cập N8N tiếp theo, bạn sẽ được yêu cầu tạo lại tài khoản owner.${NC}"

             start_spinner "Đang khởi động lại N8N service..."
             cd "${N8N_DIR}" || { stop_spinner; echo -e "${RED}Không thể truy cập ${N8N_DIR}.${NC}"; return 1; }
             if ! sudo $DOCKER_COMPOSE_CMD restart ${N8N_SERVICE_NAME} > /tmp/n8n_restart_after_reset.log 2>&1; then
                 stop_spinner
                 echo -e "${RED}Lỗi khi khởi động lại N8N service. Kiểm tra /tmp/n8n_restart_after_reset.log${NC}"
             else
                 stop_spinner
                 echo -e "${GREEN}N8N service đã được khởi động lại.${NC}"
             fi
             cd - > /dev/null
        else
            echo -e "${YELLOW}Reset có thể không thành công. Vui lòng kiểm tra output ở trên.${NC}"
        fi
    else
        echo -e "\n${RED}Lỗi khi thực thi lệnh reset thông tin owner.${NC}"
        echo -e "${YELLOW}Output từ lệnh (nếu có):${NC}"
        cat "${reset_log}"
        echo -e "${YELLOW}Kiểm tra log Docker của container ${N8N_CONTAINER_NAME} để biết thêm chi tiết.${NC}"
    fi
    sudo rm -f "${reset_log}"

    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Export Dữ Liệu ---
export_all_data() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
    fi

    echo -e "\n${CYAN}--- Export Dữ Liệu N8N (Workflows & Credentials) cho instance ${INSTANCE_NAME} ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy file cấu hình ${ENV_FILE} hoặc ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Có vẻ như instance ${INSTANCE_NAME} chưa được cài đặt. Vui lòng cài đặt trước.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local domain_name
    domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$domain_name" ]]; then
        echo -e "${RED}Lỗi: Không tìm thấy DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
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
        echo -e "\n${YELLOW}Hủy bỏ/Lỗi trong quá trình export (Mã lỗi: $RC). Đang dọn dẹp...${NC}"; \
        sudo docker exec -u node ${N8N_CONTAINER_NAME} rm -rf "${container_temp_export_dir}" &>/dev/null; \
        if [ -n "${temp_nginx_include_file_path_for_trap}" ] && [ -f "${temp_nginx_include_file_path_for_trap}" ]; then \
            sudo rm -f "${temp_nginx_include_file_path_for_trap}"; \
            if sudo nginx -t &>/dev/null; then sudo systemctl reload nginx &>/dev/null; fi; \
            echo -e "${YELLOW}Đường dẫn tải xuống tạm thời đã được gỡ bỏ.${NC}"; \
        fi; \
        read -r -p "Nhấn Enter để quay lại menu..."; \
        return 0;' ERR SIGINT SIGTERM

    start_spinner "Chuẩn bị export dữ liệu..."

    if ! sudo mkdir -p "${current_backup_dir}"; then
        stop_spinner
        echo -e "${RED}Lỗi: Không thể tạo thư mục backup ${current_backup_dir}.${NC}"
        return 1
    fi
    sudo chmod 755 "${current_backup_dir}"

    if ! sudo docker exec -u node "${N8N_CONTAINER_NAME}" mkdir -p "${container_temp_export_dir}"; then
        stop_spinner
        echo -e "${RED}Lỗi: Không thể tạo thư mục tạm trong container N8N.${NC}"
        return 1
    fi
    stop_spinner

    local export_creds_log="/tmp/n8n_export_creds.log"
    local export_creds_cmd="n8n export:credentials --all --output=${container_temp_export_dir}/${creds_file}"
    local export_creds_success=false

    start_spinner "Đang export credentials..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${export_creds_cmd} > "${export_creds_log}" 2>&1; then
        if sudo docker cp "${N8N_CONTAINER_NAME}:${container_temp_export_dir}/${creds_file}" "${current_backup_dir}/${creds_file}"; then
            export_creds_success=true
            echo -e "\r\033[K${GREEN}Export credentials thành công.${NC}"
        else
            echo -e "\r\033[K${RED}Lỗi khi sao chép ${creds_file} từ container.${NC}"
        fi
    else
        if grep -q -i "No credentials found" "${export_creds_log}" || \
           grep -q -i "No items to export" "${export_creds_log}" || \
           [ ! -f "$(sudo docker exec ${N8N_CONTAINER_NAME} ls ${container_temp_export_dir}/${creds_file} 2>/dev/null)" ]; then
            echo -e "\r\033[K${YELLOW}Không tìm thấy credentials để export. Tạo file trống...${NC}"
            echo "{}" | sudo tee "${current_backup_dir}/${creds_file}" > /dev/null
            export_creds_success=true
        else
            echo -e "\r\033[K${RED}Lỗi khi export credentials.${NC}"
            echo -e "${YELLOW}Output từ lệnh:${NC}"
            cat "${export_creds_log}"
        fi
    fi
    stop_spinner
    sudo rm -f "${export_creds_log}"
    if [[ "$export_creds_success" != true ]]; then return 1; fi

    local export_workflows_log="/tmp/n8n_export_workflows.log"
    local export_workflows_cmd="n8n export:workflow --all --output=${container_temp_export_dir}/${workflows_file}"
    local export_workflows_success=false

    start_spinner "Đang export workflows..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${export_workflows_cmd} > "${export_workflows_log}" 2>&1; then
        if sudo docker cp "${N8N_CONTAINER_NAME}:${container_temp_export_dir}/${workflows_file}" "${current_backup_dir}/${workflows_file}"; then
            export_workflows_success=true
            echo -e "\r\033[K${GREEN}Export workflows thành công.${NC}"
        else
            echo -e "\r\033[K${RED}Lỗi khi sao chép ${workflows_file} từ container.${NC}"
        fi
    else
        if grep -q -i "No workflows found" "${export_workflows_log}" || \
           grep -q -i "No items to export" "${export_workflows_log}" || \
           [ ! -f "$(sudo docker exec ${N8N_CONTAINER_NAME} ls ${container_temp_export_dir}/${workflows_file} 2>/dev/null)" ]; then
            echo -e "\r\033[K${YELLOW}Không tìm thấy workflows để export. Tạo file trống...${NC}"
            echo "[]" | sudo tee "${current_backup_dir}/${workflows_file}" > /dev/null
            export_workflows_success=true
        else
            echo -e "\r\033[K${RED}Lỗi khi export workflows.${NC}"
            echo -e "${YELLOW}Output từ lệnh:${NC}"
            cat "${export_workflows_log}"
        fi
    fi
    stop_spinner
    sudo rm -f "${export_workflows_log}"
    if [[ "$export_workflows_success" != true ]]; then return 1; fi

    echo -e "Đường dẫn lưu trữ trên server: ${YELLOW}${current_backup_dir}${NC}"

    start_spinner "Dọn dẹp thư mục tạm trong container..."
    sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_export_dir}" &>/dev/null
    stop_spinner

    local random_signature
    random_signature=$(generate_random_string 16)
    sudo mkdir -p "${NGINX_EXPORT_INCLUDE_DIR}"
    local temp_nginx_include_file="${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_${random_signature}.conf"
    temp_nginx_include_file_path_for_trap="${temp_nginx_include_file}"
    local download_path_segment="n8n-backup-${random_signature}"

    start_spinner "Tạo đường dẫn tải xuống tạm thời..."

    local nginx_export_content
    nginx_export_content=$(cat <<EOF
location /${download_path_segment}/ {
    alias ${current_backup_dir}/;
    add_header Content-Disposition "attachment";
    autoindex off;
    expires off;
}
EOF
)
    echo "$nginx_export_content" | sudo tee "${temp_nginx_include_file}" > /dev/null
    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "${RED}Lỗi khi tạo file cấu hình Nginx tạm thời: ${temp_nginx_include_file}.${NC}"
        temp_nginx_include_file_path_for_trap=""
        return 1
    fi

    if ! sudo nginx -t > /tmp/nginx_export_test.log 2>&1; then
        stop_spinner
        echo -e "${RED}Lỗi cấu hình Nginx. Kiểm tra /tmp/nginx_export_test.log.${NC}"
        sudo rm -f "${temp_nginx_include_file}"
        temp_nginx_include_file_path_for_trap=""
        return 1
    fi
    sudo systemctl reload nginx
    stop_spinner
    echo -e "${GREEN}Đường dẫn tải xuống tạm thời đã được tạo.${NC}"

    echo -e "\n${YELLOW}--- HƯỚNG DẪN TẢI XUỐNG ---${NC}"
    echo -e "Các file backup đã được export thành công."
    echo -e "Bạn có thể tải xuống qua các đường dẫn sau (chỉ có hiệu lực trong phiên này):"
    echo -e "  Credentials: ${GREEN}https://${domain_name}/${download_path_segment}/${creds_file}${NC}"
    echo -e "  Workflows:   ${GREEN}https://${domain_name}/${download_path_segment}/${workflows_file}${NC}"
    echo -e "\n${RED}QUAN TRỌNG:${NC} Sau khi bạn tải xong, nhấn Enter để vô hiệu hóa các đường dẫn này."

    read -r -p "Nhấn Enter sau khi bạn đã tải xong các file..."

    start_spinner "Vô hiệu hóa đường dẫn tải xuống..."
    sudo rm -f "${temp_nginx_include_file}"
    temp_nginx_include_file_path_for_trap=""
    if ! sudo nginx -t > /tmp/nginx_export_test_remove.log 2>&1; then
        echo -e "\n${YELLOW}Cảnh báo: Có lỗi khi kiểm tra Nginx sau khi xóa file include, nhưng vẫn tiếp tục.${NC}"
    fi
    sudo systemctl reload nginx
    stop_spinner
    echo -e "${GREEN}Đường dẫn tải xuống đã được vô hiệu hóa.${NC}"
    echo -e "Các file backup vẫn được lưu trữ tại: ${YELLOW}${current_backup_dir}${NC} trên server."

    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Import Dữ Liệu ---
import_data() {
    check_root
    if [[ -z "$INSTANCE_NAME" ]]; then
      echo -e "${YELLOW}Vui lòng chọn một instance trước (tùy chọn 12).${NC}"
      read -r -p "Nhấn Enter để quay lại menu..."
      return 0
       fi

    echo -e "${YELLOW}Chức năng này sẽ import workflows và credentials từ các file JSON được chuẩn bị trước.${NC}"
    echo -e "${YELLOW}Đảm bảo bạn đã có file credentials.json và workflows.json hợp lệ.${NC}"

    local backup_dir="${N8N_DIR}/backups/import"
    local container_temp_import_dir="/home/node/.n8n/temp_import_$$"
    local creds_file="credentials.json"
    local workflows_file="workflows.json"

    trap 'RC=$?; stop_spinner; \
        echo -e "\n${YELLOW}Hủy bỏ/Lỗi trong quá trình import (Mã lỗi: $RC). Đang dọn dẹp...${NC}"; \
        sudo docker exec -u node ${N8N_CONTAINER_NAME} rm -rf "${container_temp_import_dir}" &>/dev/null; \
        read -r -p "Nhấn Enter để quay lại menu..."; \
        return 0;' ERR SIGINT SIGTERM

    start_spinner "Chuẩn bị import dữ liệu..."

    if ! sudo mkdir -p "${backup_dir}"; then
        stop_spinner
        echo -e "${RED}Lỗi: Không thể tạo thư mục import ${backup_dir}.${NC}"
        return 1
    fi
    sudo chmod 755 "${backup_dir}"

    if ! sudo docker exec -u node "${N8N_CONTAINER_NAME}" mkdir -p "${container_temp_import_dir}"; then
        stop_spinner
        echo -e "${RED}Lỗi: Không thể tạo thư mục tạm trong container N8N.${NC}"
        return 1
    fi
    stop_spinner

    echo -e "\n${CYAN}Vui lòng đặt các file ${creds_file} và ${workflows_file} vào thư mục:${NC}"
    echo -e "${YELLOW}${backup_dir}${NC}"
    echo -e "${YELLOW}Sau khi đặt file, nhấn Enter để tiếp tục hoặc nhập '0' để hủy bỏ.${NC}"
    read -r import_choice
    if [[ "$import_choice" == "0" ]]; then
        echo -e "${GREEN}Hủy bỏ import dữ liệu.${NC}"
        sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_import_dir}" &>/dev/null
        trap - ERR SIGINT SIGTERM
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    if [[ ! -f "${backup_dir}/${creds_file}" || ! -f "${backup_dir}/${workflows_file}" ]]; then
        stop_spinner
        echo -e "${RED}Lỗi: Thiếu file ${creds_file} hoặc ${workflows_file} trong ${backup_dir}.${NC}"
        sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_import_dir}" &>/dev/null
        trap - ERR SIGINT SIGTERM
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    start_spinner "Sao chép file import vào container..."

    if ! sudo docker cp "${backup_dir}/${creds_file}" "${N8N_CONTAINER_NAME}:${container_temp_import_dir}/${creds_file}"; then
        stop_spinner
        echo -e "${RED}Lỗi khi sao chép ${creds_file} vào container.${NC}"
        return 1
    fi
    if ! sudo docker cp "${backup_dir}/${workflows_file}" "${N8N_CONTAINER_NAME}:${container_temp_import_dir}/${workflows_file}"; then
        stop_spinner
        echo -e "${RED}Lỗi khi sao chép ${workflows_file} vào container.${NC}"
        return 1
    fi
    stop_spinner

    local import_creds_log="/tmp/n8n_import_creds.log"
    local import_creds_cmd="n8n import:credentials --input=${container_temp_import_dir}/${creds_file} --separate"
    local import_creds_success=false

    start_spinner "Đang import credentials..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${import_creds_cmd} > "${import_creds_log}" 2>&1; then
        if grep -q -i "Credentials imported successfully" "${import_creds_log}" || \
           grep -q -i "No credentials found" "${import_creds_log}"; then
            import_creds_success=true
            echo -e "\r\033[K${GREEN}Import credentials thành công.${NC}"
        else
            echo -e "\r\033[K${RED}Lỗi khi import credentials.${NC}"
            echo -e "${YELLOW}Output từ lệnh:${NC}"
            cat "${import_creds_log}"
        fi
    else
        echo -e "\r\033[K${RED}Lỗi khi import credentials.${NC}"
        echo -e "${YELLOW}Output từ lệnh:${NC}"
        cat "${import_creds_log}"
    fi
    stop_spinner
    sudo rm -f "${import_creds_log}"
    if [[ "$import_creds_success" != true ]]; then return 1; fi

    local import_workflows_log="/tmp/n8n_import_workflows.log"
    local import_workflows_cmd="n8n import:workflow --input=${container_temp_import_dir}/${workflows_file} --separate"
    local import_workflows_success=false

    start_spinner "Đang import workflows..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${import_workflows_cmd} > "${import_workflows_log}" 2>&1; then
        if grep -q -i "Workflows imported successfully" "${import_workflows_log}" || \
           grep -q -i "No workflows found" "${import_workflows_log}"; then
            import_workflows_success=true
            echo -e "\r\033[K${GREEN}Import workflows thành công.${NC}"
        else
            echo -e "\r\033[K${RED}Lỗi khi import workflows.${NC}"
            echo -e "${YELLOW}Output từ lệnh:${NC}"
            cat "${import_workflows_log}"
        fi
    else
        echo -e "\r\033[K${RED}Lỗi khi import workflows.${NC}"
        echo -e "${YELLOW}Output từ lệnh:${NC}"
        cat "${import_workflows_log}"
    fi
    stop_spinner
    sudo rm -f "${import_workflows_log}"
    if [[ "$import_workflows_success" != true ]]; then return 1; fi

    start_spinner "Dọn dẹp thư mục tạm trong container..."
    sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_import_dir}" &>/dev/null
    stop_spinner

    echo -e "\n${GREEN}Import dữ liệu hoàn tất!${NC}"
    echo -e "${YELLOW}Workflows và credentials đã được import vào instance ${INSTANCE_NAME}.${NC}"
    echo -e "Vui lòng kiểm tra giao diện web của N8N để xác nhận dữ liệu."

    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhấn Enter để quay lại menu chính...${NC}"
    read -r
}

# --- Hàm Tạo Instance Mới ---
create_new_instance() {
    check_root
    echo -e "\n${CYAN}--- Tạo Instance N8N Mới ---${NC}"

    local new_instance_name
    echo -n -e "${CYAN}Nhập tên cho instance mới (chỉ dùng chữ cái, số, dấu gạch ngang): ${NC}"
    read -r new_instance_name

    if [[ -z "$new_instance_name" ]]; then
        echo -e "${RED}Tên instance không được để trống.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    if ! [[ "$new_instance_name" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo -e "${RED}Tên instance chỉ được chứa chữ cái, số và dấu gạch ngang (-).${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local new_instance_dir="${INSTANCES_DIR}/${new_instance_name}"
    if [ -d "${new_instance_dir}" ]; then
        echo -e "${YELLOW}Instance ${new_instance_name} đã tồn tại tại ${new_instance_dir}.${NC}"
        echo -e "${YELLOW}Vui lòng chọn tên khác hoặc xóa instance hiện có (tùy chọn 10).${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    echo -e "${YELLOW}Bạn có chắc chắn muốn tạo instance mới '${new_instance_name}' không?${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Nhập '${GREEN}ok${NC}' để xác nhận, hoặc bất kỳ phím nào khác để hủy bỏ: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "${GREEN}Hủy bỏ tạo instance mới.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; echo -e "\n${RED}Lỗi trong quá trình tạo instance (Mã lỗi: $RC).${NC}"; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang tạo instance ${new_instance_name}..."

    sudo mkdir -p "${new_instance_dir}"
    INSTANCE_NAME="${new_instance_name}"
    N8N_DIR="${new_instance_dir}"
    ENV_FILE="${N8N_DIR}/.env"
    DOCKER_COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"

    stop_spinner
    echo -e "${GREEN}Instance ${new_instance_name} đã được tạo tại ${new_instance_dir}.${NC}"
    echo -e "${YELLOW}Bạn cần cài đặt n8n cho instance này (tùy chọn 1).${NC}"

    trap - ERR SIGINT SIGTERM
    read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Hàm Chọn Instance ---
select_instance() {
    check_root
    echo -e "\n${CYAN}--- Chọn Instance N8N ---${NC}"

    if [ ! -d "${INSTANCES_DIR}" ] || [ -z "$(ls -A "${INSTANCES_DIR}")" ]; then
        echo -e "${YELLOW}Không tìm thấy instance nào trong ${INSTANCES_DIR}.${NC}"
        echo -e "${YELLOW}Vui lòng tạo instance mới (tùy chọn 11).${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    local instances=($(ls -1 "${INSTANCES_DIR}"))
    echo -e "${CYAN}Danh sách instance hiện có:${NC}"
    for i in "${!instances[@]}"; do
        echo -e "  ${GREEN}$((i+1)). ${instances[i]}${NC}"
    done

    local choice
    echo -n -e "\n${CYAN}Nhập số thứ tự của instance bạn muốn chọn (hoặc '0' để hủy): ${NC}"
    read -r choice

    if [[ "$choice" == "0" ]]; then
        echo -e "${GREEN}Hủy bỏ chọn instance.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#instances[@]}" ]; then
        echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    INSTANCE_NAME="${instances[$((choice-1))]}"
    N8N_DIR="${INSTANCES_DIR}/${INSTANCE_NAME}"
    ENV_FILE="${N8N_DIR}/.env"
    DOCKER_COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"

    echo -e "${GREEN}Đã chọn instance: ${INSTANCE_NAME}${NC}"
    echo -e "${YELLOW}Tất cả thao tác tiếp theo sẽ áp dụng cho instance này.${NC}"
    read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Hàm Cài đặt NocoDB ---
install_nocodb() {
    check_root
    echo -e "\n${CYAN}--- Cài đặt NocoDB ---${NC}"

    local nocodb_dir="/nocodb"
    local nocodb_env_file="${nocodb_dir}/.env"
    local nocodb_docker_compose_file="${nocodb_dir}/docker-compose.yml"

    if [ -d "${nocodb_dir}" ] && [ -f "${nocodb_docker_compose_file}" ]; then
        echo -e "${YELLOW}Phát hiện NocoDB đã được cài đặt tại ${nocodb_dir}.${NC}"
        echo -e "${YELLOW}Vui lòng xóa thư mục ${nocodb_dir} nếu muốn cài đặt lại.${NC}"
        read -r -p "Nhấn Enter để quay lại menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; echo -e "\n${RED}Lỗi trong quá trình cài đặt NocoDB (Mã lỗi: $RC).${NC}"; read -r -p "Nhấn Enter để quay lại menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Đang cài đặt NocoDB..."

    install_prerequisites
    sudo mkdir -p "${nocodb_dir}"
    sudo touch "${nocodb_env_file}"
    sudo chmod 600 "${nocodb_env_file}"

    local nocodb_domain
    if ! get_domain_and_dns_check_reusable nocodb_domain "" "Nhập tên miền cho NocoDB (ví dụ: nocodb.example.com)"; then
        return 0
    fi
    update_env_file "NOCODB_DOMAIN" "${nocodb_domain}" "${nocodb_env_file}"
    update_env_file "NC_DB" "pg://postgres:5432?u=${POSTGRES_USER:-nocodb_user}&p=${POSTGRES_PASSWORD:-$(generate_random_string 32)}&d=nocodb_db" "${nocodb_env_file}"

    start_spinner "Tạo file docker-compose.yml cho NocoDB..."
    sudo bash -c "cat > ${nocodb_docker_compose_file}" <<EOF
services:
  nocodb_postgres:
    image: postgres:15-alpine
    restart: always
    container_name: nocodb_postgres
    environment:
      - POSTGRES_USER=nocodb_user
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-$(generate_random_string 32)}
      - POSTGRES_DB=nocodb_db
    volumes:
      - nocodb_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nocodb_user -d nocodb_db"]
      interval: 5s
      timeout: 5s
      retries: 10

  nocodb:
    image: nocodb/nocodb:latest
    restart: always
    container_name: nocodb_app
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - NC_DB=\${NC_DB}
      - NC_AUTH_TYPE=default
    depends_on:
      nocodb_postgres:
        condition: service_healthy
    volumes:
      - nocodb_data:/usr/app/data

volumes:
  nocodb_postgres_data:
  nocodb_data:
EOF
    stop_spinner

    start_spinner "Khởi chạy container NocoDB..."
    cd "${nocodb_dir}" || { return 1; }
    run_silent_command "Tải Docker images" "$DOCKER_COMPOSE_CMD pull" "false"
    run_silent_command "Khởi chạy container" "$DOCKER_COMPOSE_CMD up -d --force-recreate" "false"
    cd - > /dev/null
    stop_spinner

    start_spinner "Cấu hình Nginx và SSL cho NocoDB..."
    local nginx_conf_file="/etc/nginx/sites-available/${nocodb_domain}.conf"
    sudo bash -c "cat > ${nginx_conf_file}" <<EOF
server {
    listen 80;
    server_name ${nocodb_domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${nocodb_domain};

    ssl_certificate /etc/letsencrypt/live/${nocodb_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${nocodb_domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
    }
}
EOF
    sudo ln -sfn "${nginx_conf_file}" "/etc/nginx/sites-enabled/${nocodb_domain}.conf"
    sudo certbot --nginx -d "${nocodb_domain}" --email "no-reply@${nocodb_domain}" --non-interactive --agree-tos
    sudo systemctl reload nginx
    stop_spinner

    echo -e "${GREEN}Cài đặt NocoDB hoàn tất!${NC}"
    echo -e "Bạn có thể truy cập NocoDB tại: ${GREEN}https://${nocodb_domain}${NC}"

    trap - ERR SIGINT SIGTERM
    read -r -p "Nhấn Enter để quay lại menu..."
}

# --- Hàm Menu Chính ---
show_menu() {
    clear
    echo -e "${CYAN}===================================================${NC}"
    echo -e "${CYAN}        N8N Cloud Manager - Instance: ${INSTANCE_NAME:-None}${NC}"
    echo -e "${CYAN}===================================================${NC}"
    echo -e "${GREEN}1)  Cài đặt N8N Cloud${NC}"
    echo -e "${GREEN}2)  Lấy thông tin Redis${NC}"
    echo -e "${GREEN}3)  Thay đổi tên miền${NC}"
    echo -e "${GREEN}4)  Nâng cấp phiên bản N8N${NC}"
    echo -e "${GREEN}5)  Tắt xác thực 2 bước (2FA/MFA)${NC}"
    echo -e "${GREEN}6)  Đặt lại thông tin đăng nhập${NC}"
    echo -e "${GREEN}7)  Export tất cả (workflow & credentials)${NC}"
    echo -e "${GREEN}8)  Import workflow & credentials${NC}"
    echo -e "${GREEN}9)  Cài đặt NocoDB${NC}"
    echo -e "${GREEN}10) Xóa N8N và cài đặt lại${NC}"
    echo -e "${GREEN}11) Tạo instance mới${NC}"
    echo -e "${GREEN}12) Chọn instance${NC}"
    echo -e "${GREEN}0)  Thoát${NC}"
    echo -e "${CYAN}===================================================${NC}"
    echo -n -e "${YELLOW}Nhập lựa chọn của bạn: ${NC}"
}

# --- Hàm Chính ---
main() {
    check_root
    sudo mkdir -p "${INSTANCES_DIR}"
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) install ;;
            2) get_redis_info ;;
            3) change_domain ;;
            4) upgrade_n8n_version ;;
            5) disable_mfa ;;
            6) reset_user_login ;;
            7) export_all_data ;;
            8) import_data ;;
            9) install_nocodb ;;
            10) reinstall_n8n ;;
            11) create_new_instance ;;
            12) select_instance ;;
            0)
                echo -e "${GREEN}Đang thoát...${NC}"
                exit 0
            ;;
            *)
                echo -e "${RED}Lựa chọn không hợp lệ. Vui lòng thử lại.${NC}"
                read -r -p "Nhấn Enter để tiếp tục..."
            ;;
        esac
    done
}

# --- Chạy Script ---
main
