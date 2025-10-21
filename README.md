Automated Deployment Bash Script
Overview
This repository contains a Bash script (deploy.sh) designed to automate the setup, deployment, and configuration of a Dockerized application on a remote Linux server. The script is built to be robust, idempotent, and production-grade, with error handling, logging, and validation at each stage. It follows the requirements outlined in the DevOps Intern Stage 1 Task.
This script is POSIX-compliant and executable (run chmod +x deploy.sh before use). It does not rely on external configuration management tools like Ansible or Terraform.
Prerequisites

Local Machine:

Git installed.
SSH key-based access to the remote server (no password prompts).
rsync and ssh commands available.


Remote Server:

Linux distribution (tested on Ubuntu/Debian; may require adjustments for others like CentOS).
Sudo privileges for the SSH user (for package installation and service management).
Internet access for installing Docker, Docker Compose, and Nginx.


Repository:

A GitHub repository with a Dockerfile or docker-compose.yml.
A Personal Access Token (PAT) with repo read permissions.


Application:

The app should expose a port (e.g., via EXPOSE in Dockerfile) that matches the user-provided application port.



Usage

Clone this repository:
textgit clone <your-repo-url>
cd <repo-name>

Make the script executable:
textchmod +x deploy.sh

Run the script:
text./deploy.sh

The script will prompt for inputs: Git Repo URL, PAT, Branch (default: main), SSH Username, Server IP, SSH Key Path, Application Port.
All actions are logged to a timestamped file (e.g., deploy_YYYYMMDD_HHMMSS.log).


For cleanup (optional):
text./deploy.sh --cleanup

This removes deployed resources (containers, Nginx config, files) without prompts.



Script Workflow
The script performs the following steps sequentially:

Collect Parameters: Prompts and validates user inputs.
Clone Repository: Clones or pulls the latest from the specified Git repo/branch using PAT.
Verify Docker Config: Checks for Dockerfile or docker-compose.yml.
Test SSH Connection: Verifies connectivity to the remote server.
Setup Remote Environment: Installs/updates Docker, Docker Compose, Nginx; starts services.
Transfer Files: Uses rsync to copy the project to the remote server (excludes .git and logs).
Deploy Application: Stops old containers, builds/runs the app (via docker build/run or docker-compose up).
Configure Nginx: Sets up a reverse proxy to forward port 80 to the app's internal port.
Validate Deployment: Checks services, container health, and accessibility via curl.
Logging & Error Handling: Logs all actions; traps errors for graceful failure.

Example Inputs

Git Repository URL: https://github.com/username/my-app-repo.git
Personal Access Token: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Branch: main
SSH Username: ubuntu
Server IP: 192.168.1.100
SSH Key Path: ~/.ssh/id_rsa
Application Port: 8080 (must match the app's listening port)

Testing

Tested on Ubuntu 22.04 remote server.
Sample app included: A simple Flask app (app.py, Dockerfile, requirements.txt) for demonstration.
Run on a test server to avoid disrupting production environments.
Common issues: Ensure SSH key permissions (chmod 600 ~/.ssh/id_rsa), firewall allows port 80 (ufw allow 80), and app port matches.

Limitations & Improvements

Assumes Debian-based remote OS; add distro detection for broader support.
No SSL configuration (placeholder for Certbot/self-signed cert can be added).
Sensitive inputs (e.g., PAT) are not hidden; use read -s for production.
For idempotency, re-runs are safe but may require sudo for Docker if group changes not applied.