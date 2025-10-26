# Stage 1: Automated Docker Deployment Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![POSIX Compliant](https://img.shields.io/badge/POSIX-Compliant-blue.svg)](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/contents.html)

A production-grade, idempotent Bash script (`deploy.sh`) that automates the setup, deployment, and proxying of a Dockerized app to a remote Linux server (e.g., AWS EC2 Ubuntu). Handles Git clone/pull, SSH connectivity, Docker/Nginx installs, file transfer, container build/run, reverse proxy config, and health checks—with logging, error traps.

Inspired by real CI/CD workflows: Safe re-runs, no duplicates, stage-specific exit codes (0=success, 1=error).

## Features
- **Interactive Params**: Validates Git URL, PAT, branch, SSH creds, app port.
- **Idempotent Repo Ops**: Clone/pull + branch switch; verifies Dockerfile/docker-compose.yml.
- **Remote Prep**: Updates pkgs, installs Docker/Compose/Nginx if missing; adds user to Docker group.
- **Deployment**: Rsync files, builds/runs container (detached, restart policy), health curl.
- **Nginx Proxy**: Dynamic config for 80 → internal port; SSL placeholder (Certbot-ready).
- **Validation**: Checks services/containers/proxy; external curl test.
- **Logging**: Timestamped file (e.g., `deploy_YYYYMMDD.log`); traps for interrupts.
- **Cleanup Flag**: `./deploy.sh --cleanup` removes container/dir/config.

## Prerequisites
- **Local**: Bash 4+ (POSIX), Git, SSH client, rsync, Docker (for local tests).
- **Remote Server**: Linux (Ubuntu/Debian tested), SSHD on port 22, sudo access for ubuntu/ec2-user.
- **AWS EC2 Example**: t3.micro Ubuntu 24.04, Security Group open: 22 (SSH from your IP), 80 (HTTP Anywhere), 3000 (App from your IP), ICMP (Ping from your IP).
- **GitHub**: Repo with Dockerfile (or docker-compose.yml); PAT for private (repo:contents read).
- **SSH Key**: PEM/RSA key (chmod 400); pubkey in remote `~/.ssh/authorized_keys`.

## Installation
1. Clone this repo: `git clone https://github.com/yourusername/hng-devops-deploy.git`
2. `cd hng-devops-deploy`
3. `chmod +x deploy.sh`

## Usage
Run interactively: `./deploy.sh`

### Prompts & Validation
| Param | Prompt | Default/Validation | Example |
|-------|--------|---------------------|---------|
| Git URL | Git Repository URL | Regex: `https://github.com/user/repo.git` | `https://github.com/Praise650/devops-stage-1.git` |
| PAT | Personal Access Token | Required (non-empty) | `github_pat_...` (fine-grained, repo read) |
| Branch | Branch name | `main` | `main` |
| SSH User | SSH Username | Required (non-empty) | `ubuntu` |
| Server IP | Server IP Address | IPv4 regex | `13.60.51.188` |
| SSH Key | SSH Key Path | `~/.ssh/id_rsa` | `/path/to/hng-intern-key.pem` |
| App Port | App Port (internal) | Numeric (1-65535) | `3000` |

### Sample Run
```bash
$ ./deploy.sh
[2025-10-22 05:XX:XX] === Starting Deployment ===
Git Repository URL: https://github.com/Praise650/devops-stage-1.git
... (prompts)
[2025-10-22 05:XX:XX] Params validated...
... (clone, SSH, prep, deploy, proxy, validate)
[2025-10-22 05:XX:XX] Validation: Stack solid. Full deploy success!
[2025-10-22 05:XX:XX] === EOF Deployment ===
```
- **Output**: Logs to `deploy_YYYYMMDD.log` (tee'd to console). Tail: `tail -f deploy_*.log`.
- **Success**: App at `http://<SERVER_IP>:80` (proxied) or `:3000` (direct). Curl: "HNG Stage One Automate Docker Deployment"

## Testing
### Local (Steps 1-3)
- Mock SSH: Comment Step 4+ in script.
- `./deploy.sh` → Validates params, clones/pulls repo, checks Dockerfile.
- Local App Test: `docker build -t sample . && docker run -p 3000:3000 sample` → `curl localhost:3000`.

### Full End-to-End
- AWS EC2: Launch Ubuntu t3.micro (see Prereqs), run script.
- Verify: `curl http://<IP>` ("Hello..."), `ssh user@IP "docker ps"` (app-container UP).
- Idempotency: Re-run → Pulls updates, restarts container, no dups.
- Edge: Bad URL → Exit 1, log "Invalid Git URL...".

Tested on: Ubuntu 24.04 (local/remote), Node.js sample app (port 3000).

## Error Handling & Exit Codes
- **Traps**: SIGINT/TERM → Logs interrupt, exits 130.
- **Stages**: Exit 1 on fail (e.g., clone=1, SSH=2—customize via vars).
- **Common Fixes**:
  - SSH Refused: SG port 22 open, SSHD started (`sudo systemctl start ssh`).
  - Rsync Denied: Script auto-chowns `/opt/app`; manual: `sudo chown -R ubuntu:ubuntu /opt/app`.
  - Build Fail: Dockerfile syntax; check remote logs: `docker logs app-container`.
  - Proxy 502: Container down? `docker restart app-container`.

## Limitations & Future
- Single-container (Dockerfile); extend for compose.yml multi-service.
- No Terraform/Ansible (per task)—pure Bash.
- SSL: Placeholder; add Certbot in prod (`sudo certbot --nginx`).

## License
MIT—fork, star, contribute! 🚀

Built for HNG DevOps Intern Stage 1. Questions? @editortechbro on Slack.
