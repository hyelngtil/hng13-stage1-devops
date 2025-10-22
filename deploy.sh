#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, pipe failures

# Create timestamped log file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Trap errors
trap 'log "ERROR: Script failed at line $LINENO"' ERR

# Function to read input with validation
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

# Collect parameters
GIT_REPO=$(read_input "Enter Git Repository URL" "GIT_REPO")
PAT=$(read_input "Enter Personal Access Token" "PAT")
BRANCH=$(read_input "Enter branch name [main]" "BRANCH" "main")
SSH_USER=$(read_input "Enter SSH username" "SSH_USER")
SERVER_IP=$(read_input "Enter server IP address" "SERVER_IP")
SSH_KEY=$(read_input "Enter SSH key path" "SSH_KEY")
APP_PORT=$(read_input "Enter application port" "APP_PORT")

# Function to clone repository
clone_repo() {
    local repo_url="$1"
    local token="$2"
    local branch="$3"
    
    # Extract repo name
    REPO_NAME=$(basename "$repo_url" .git)
    
    # Construct authenticated URL
    AUTH_URL=$(echo "$repo_url" | sed "s|https://|https://${token}@|")
    
    if [[ -d "$REPO_NAME" ]]; then
        log "Repository exists, pulling latest changes..."
        cd "$REPO_NAME"
        git pull origin "$branch" || exit 2
    else
        log "Cloning repository..."
        git clone -b "$branch" "$AUTH_URL" || exit 2
        cd "$REPO_NAME"
    fi
    
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
    local user="$1"
    local ip="$2"
    local key="$3"
    
    log "Testing SSH connection..."
    
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
    local user="$1"
    local ip="$2"
    local key="$3"
    
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
    local user="$1"
    local ip="$2"
    local key="$3"
    local app_port="$4"
    
    log "Deploying application..."
    
    ssh -i "$key" "$user@$ip" bash -s << ENDSSH
        set -e
        cd ~/deployment/$REPO_NAME
        
        # Stop old containers
        docker-compose down 2>/dev/null || docker stop \$(docker ps -q) 2>/dev/null || true
        
        # Remove stopped containers to free names
        docker rm \$(docker ps -aq --filter "name=my-app") 2>/dev/null || true

        # Build and start
        if [[ -f "docker-compose.yml" ]]; then
            docker-compose up -d --build
        else
            docker build -t my-app .
            docker run -d -p $app_port:$app_port --name my-app my-app
        fi
        
        # Wait for container to be healthy
        sleep 5
        
        # Verify container is running
        docker ps | grep -E "my-app|$REPO_NAME"
ENDSSH
    
    log "✓ Application deployed successfully"
}

# Function to transfer application files to the remote server
transfer_files() {
    local user="$1"
    local ip="$2"
    local key="$3"
    local local_dir="$4"
    
    log "Transferring application files..."
    
    # 1. Ensure the remote deployment directory exists
    ssh -i "$key" "$user@$ip" "mkdir -p ~/deployment" || exit 9
    
    # The REPO_NAME is globally available from the clone_repo call
    local REPO_TO_COPY="$local_dir/$REPO_NAME"
    
    # Check for the local directory before copying
    if [[ ! -d "$REPO_TO_COPY" ]]; then
        log "ERROR: Local repository directory '$REPO_TO_COPY' not found."
        exit 10
    fi

    # Clean up existing remote repo dir to avoid conflicts/permissions issues
    ssh -i "$key" "$user@$ip" "rm -rf ~/deployment/$REPO_NAME" || true
    
    # Copy the repository folder recursively into the remote deployment folder
    #scp -r -i "$key" "$REPO_TO_COPY" "$user@$ip:~/deployment/" || exit 11
    # Transfer with rsync, excluding .git and logs
    rsync -avz -e "ssh -i $key" --exclude='.git/' --exclude='deploy_*.log' "$REPO_TO_COPY/" "$user@$ip:~/deployment/$REPO_NAME/" || exit 11

    log "✓ Files transferred successfully to ~/deployment/$REPO_NAME"
}

# Configure Nginx as reverse proxy
configure_nginx() {
    local user="$1"
    local ip="$2"
    local key="$3"
    local app_port="$4"
    
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
    local user="$1"
    local ip="$2"
    local key="$3"
    
    log "Validating deployment..."
    
    # Check Docker service
    ssh -i "$key" "$user@$ip" "systemctl is-active docker" || exit 5
    
    # Check container health
    ssh -i "$key" "$user@$ip" "docker ps --filter 'status=running'" || exit 6
    
    # Check Nginx
    ssh -i "$key" "$user@$ip" "systemctl is-active nginx" || exit 7
    
    # Test endpoint
    if curl -f -s "http://$ip" > /dev/null; then
        log "✓ Application is accessible"
    else
        log "✗ Application not accessible"
        exit 8
    fi
    
    log "✓ All validation checks passed"
}

cleanup() {
    local user="$1"
    local ip="$2"
    local key="$3"
    
    log "Cleaning up deployment..."
    
    ssh -i "$key" "$user@$ip" bash -s << 'ENDSSH'
        # Stop and remove containers
        docker-compose down -v 2>/dev/null || true
        docker stop $(docker ps -aq) 2>/dev/null || true
        docker rm $(docker ps -aq) 2>/dev/null || true
        
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

# Run main function
main