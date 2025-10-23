#!/bin/bash

set -euo pipefail

# Create timestamped log file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Trap errors
trap 'log "ERROR: Script failed at line $LINENO"' ERR

# Read input with validation
read_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    
    read -p "$prompt: " value
    value="${value:-$default}"
    
    if [[ -z "$value" && -z "$default" ]]; then
        log "ERROR: $var_name cannot be empty"
        exit 1
    fi
    
    echo "$value"
}

# Gather inputs

GIT_REPO=$(read_input "Enter Git Repository URL" "GIT_REPO")
BRANCH=$(read_input "Enter branch name [main]" "BRANCH" "main")

# PAT: Silent read, validate non-empty
echo -n "PAT: "; stty -echo; read -r PAT; stty echo; echo
[[ -n "$PAT" ]] || { echo "Error: PAT required" >&2; exit 1; }

SSH_USER=$(read_input "Enter SSH username" "SSH_USER")
SERVER_IP=$(read_input "Enter server IP address" "SERVER_IP")
APP_PORT=$(read_input "Enter application port" "APP_PORT")
SSH_KEY=$(read_input "Enter SSH key path" "SSH_KEY")
#: Silent, validate file/permissions
#echo -n "SSH Key Path: "; stty -echo; read -r SSH_KEY; stty echo; echo
#[[ -f "$SSH_KEY" ]] || { echo "Error: Key invalid" >&2; exit 1; }
#chmod 600 "$SSH_KEY" || log "WARN: chmod 400 failed for $SSH_KEY (continuing)"

# Clone Git repository with authentication (not exposing PAT)
clone_repo() {
    local repo_url="$1" token="$2" branch="$3"
    REPO_NAME=$(basename "$repo_url" .git)
    export REPO_NAME

    # create a temporary GIT_ASKPASS helper that prints the PAT
    TMP_ASKPASS="$(mktemp)"
    cat > "$TMP_ASKPASS" <<'EOF'
#!/bin/sh
# Git calls this script to obtain a password. It expects the password on stdout.
echo "$GIT_PASSWORD"
EOF
    chmod +x "$TMP_ASKPASS"

    # Use GIT_ASKPASS to provide the token securely to git
    if [[ -d "$REPO_NAME" ]]; then
        log "Repository exists, updating to latest changes on branch '$branch'..."
        cd "$REPO_NAME" || { rm -f "$TMP_ASKPASS"; exit 2; }
        GIT_PASSWORD="$token" GIT_ASKPASS="$TMP_ASKPASS" git fetch origin || { rm -f "$TMP_ASKPASS"; exit 2; }
        GIT_PASSWORD="$token" GIT_ASKPASS="$TMP_ASKPASS" git checkout "$branch" || { rm -f "$TMP_ASKPASS"; exit 2; }
        GIT_PASSWORD="$token" GIT_ASKPASS="$TMP_ASKPASS" git pull origin "$branch" || { rm -f "$TMP_ASKPASS"; exit 2; }
    else
        log "Cloning repository on branch '$branch'..."
        GIT_PASSWORD="$token" GIT_ASKPASS="$TMP_ASKPASS" git clone -b "$branch" "$repo_url" || { rm -f "$TMP_ASKPASS"; exit 2; }
        cd "$REPO_NAME" || { rm -f "$TMP_ASKPASS"; exit 2; }
    fi

    rm -f "$TMP_ASKPASS"
    log "Successfully cloned/updated repository"
}

# Function to verify Docker configuration
verify_docker_config() {
    if [[ -f "Dockerfile" ]] || [[ -f "docker-compose.yml" ]]; then
        log "✓ Docker configuration found"
        return 0
    else
        log "✗ No Dockerfile or docker-compose.yml found"
        exit 3
    fi
}

# Function to test SSH connection
test_ssh() {
    local user="$1" ip="$2" key="$3"
    
    log "Testing SSH connection to $user@$ip..."
    
    if ssh -i "$key" -o ConnectTimeout=10 -o BatchMode=yes \
           "$user@$ip" "echo 'SSH connection successful'" &>/dev/null; then
        log "✓ SSH connection successful"
        return 0
    else
        log "✗ SSH connection failed"
        exit 4
    fi
}

# Function to setup remote environment
setup_remote_environment() {
    local user="$1" ip="$2" key="$3"
    
    log "Setting up remote environment..."
    
    # Execute commands on remote server
    ssh -i "$key" "$user@$ip" 'bash -s' << 'ENDSSH'
        set -e
        
        # Update packages
        sudo apt-get update -y
        
        # Install Docker
        if ! command -v docker &> /dev/null; then
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            sudo usermod -aG docker $USER
        fi
        
        # Install Docker Compose
        if ! command -v docker-compose &> /dev/null; then
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        fi
        
        # Install Nginx
        if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
        fi
        
        # Start services
        sudo systemctl enable docker nginx
        sudo systemctl start docker nginx
        
        # Verify installations
        docker --version
        docker-compose --version
        nginx -v
ENDSSH
    
    log "✓ Remote environment ready"
}

# Deploy Docker application
deploy_application() {
    local user="$1" ip="$2" key="$3" app_port="$4"
    
    log "Deploying application..."
    
    ssh -i "$key" "$user@$ip" bash -s << ENDSSH || { log "✗ Deploy failed (check connection/logs)"; exit 1; }
        set -e
        mkdir -p ~/deployment
        cd ~/deployment/$REPO_NAME || { echo "Error: Repo dir not found" >&2; exit 1; }
        
        # Stop old containers
        docker-compose down 2>/dev/null || docker stop \$(docker ps -q) 2>/dev/null || true
        
        # Remove stopped containers to free names
        docker rm \$(docker ps -aq --filter "name=my-app") 2>/dev/null || true

        # Build and start
        if [[ -f "docker-compose.yml" ]]; then
            docker-compose up -d --build --force-recreate
        else
            docker build -t my-app .
            docker run -d -p $app_port:$app_port --name my-app my-app
        fi
        
        # Wait for container to be healthy
        sleep 5
        
        # Verify container is running
        if docker ps | grep -qE "my-app|$REPO_NAME"; then
            echo "✓ Containers running"
        else
            echo "✗ No running containers found" >&2
            exit 1
        fi
ENDSSH
    log "✓ Application deployed successfully"
}

# Function to transfer application files to the remote server
transfer_files() {
    local user="$1" ip="$2" key="$3" local_dir="$4"
    
    log "Transferring application files..."
    
    # Ensure the remote deployment directory exists
    ssh -i "$key" "$user@$ip" "mkdir -p ~/deployment" || exit 9
    
    # The REPO_NAME is globally available from the clone_repo call
    local REPO_TO_COPY="$local_dir/$REPO_NAME"
    if [[ ! -d "$REPO_TO_COPY" ]]; then
        log "ERROR: Local repository directory '$REPO_TO_COPY' not found."
        exit 10
    fi

    # Optional: Clean up existing remote repo dir to avoid conflicts/permissions issues
    #ssh -i "$key" "$user@$ip" "rm -rf ~/deployment/$REPO_NAME" || true
    
    # Transfer with rsync, excluding .git and logs
    rsync -avz -e "ssh -i '$key'" --exclude='.git/' --exclude='deploy_*.log' "$REPO_TO_COPY/" "$user@$ip:~/deployment/$REPO_NAME/" || exit 11


    log "✓ Files transferred successfully to ~/deployment/$REPO_NAME"
}

# Configure Nginx as reverse proxy
configure_nginx() {
    local user="$1" ip="$2" key="$3" app_port="$4"
    
    log "Configuring Nginx..."
    
    # Create Nginx config
    NGINX_CONFIG="
server {
    listen 80;
    server_name $ip;
    
    location / {
        proxy_pass http://localhost:$app_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"
    
    # Deploy config
    ssh -i "$key" "$user@$ip" bash -s << ENDSSH
        echo '$NGINX_CONFIG' | sudo tee /etc/nginx/sites-available/app.conf
        sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/
        sudo nginx -t
        sudo systemctl reload nginx
ENDSSH
    
    log "✓ Nginx configured successfully"
}

validate_deployment() {
    local user="$1" ip="$2" key="$3"
    
    log "Validating deployment..."
    
    # Check container health with fallback if no HEALTHCHECK is defined
    CONTAINER_NAME="my-app"
    HEALTH_STATUS=$(ssh -i "$key" "$user@$ip" "docker inspect --format '{{.State.Health.Status}}' $CONTAINER_NAME 2>/dev/null || true")


    if [[ -n "$HEALTH_STATUS" ]]; then
        if [[ "$HEALTH_STATUS" != "healthy" ]]; then
            log "✗ Container $CONTAINER_NAME not healthy (status: $HEALTH_STATUS)"
            exit 6
        fi
    else
        # Fallback: ensure container exists and is running
        if ! ssh -i "$key" "$user@$ip" "docker ps --filter name=$CONTAINER_NAME --filter status=running --format '{{.Names}}' | grep -q ."; then
            log "✗ Container $CONTAINER_NAME not running"
            exit 6
        fi
    fi

    # App endpoint with retries
    MAX_RETRIES=3
    for i in $(seq 1 $MAX_RETRIES); do
        if curl -f -s "http://$ip/" > /dev/null; then
            log "✓ Application /health accessible"
            break
        fi
        [[ $i -eq $MAX_RETRIES ]] && { log "✗ /health failed after $MAX_RETRIES tries"; exit 8; }
        sleep $((i * 2))  # Backoff: 2s, 4s, 6s
    done
    log "✓ All validation checks passed"
}

cleanup() {
    local user="$1" ip="$2" key="$3"
    
    log "Cleaning up deployment..."
    
    ssh -i "$key" "$user@$ip" bash -s << 'ENDSSH' || exit 15
        # Stop and remove containers
        docker-compose down -v 2>/dev/null || true
        docker stop $(docker ps -aq --filter "name=^my-app") 2>/dev/null || true
        docker rm $(docker ps -aq --filter "name=^my-app") 2>/dev/null || true
        
        # Remove Nginx config
        sudo rm -f /etc/nginx/sites-enabled/app.conf
        sudo rm -f /etc/nginx/sites-available/app.conf
        sudo systemctl reload nginx
        
        # Remove deployment files
        rm -rf ~/deployment
ENDSSH
    
    log "✓ Cleanup completed"
}

# Check for cleanup flag
if [[ "${1:-}" == "--cleanup" ]]; then
    cleanup "$SSH_USER" "$SERVER_IP" "$SSH_KEY"
    exit 0
fi

main() {
    local original_dir="$(pwd)"  # Capture parent dir before any cd
    log "===== Starting Deployment ====="
    log "Repository: $GIT_REPO"
    log "Branch: $BRANCH"
    log "Target Server: $SERVER_IP"
    
    # Execute steps in sequence
    clone_repo "$GIT_REPO" "$PAT" "$BRANCH"
    verify_docker_config
    cd "$original_dir" || exit 12  # Reset to parent dir for correct transfer path
    test_ssh "$SSH_USER" "$SERVER_IP" "$SSH_KEY"
    setup_remote_environment "$SSH_USER" "$SERVER_IP" "$SSH_KEY"
    transfer_files "$SSH_USER" "$SERVER_IP" "$SSH_KEY" "$(pwd)"
    deploy_application "$SSH_USER" "$SERVER_IP" "$SSH_KEY" "$APP_PORT"
    configure_nginx "$SSH_USER" "$SERVER_IP" "$SSH_KEY" "$APP_PORT"
    validate_deployment "$SSH_USER" "$SERVER_IP" "$SSH_KEY"
    
    log "===== Deployment Completed Successfully ====="
}

main