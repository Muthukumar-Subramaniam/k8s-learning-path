# 🐳 Docker Complete Practical Guide

A comprehensive, hands-on guide to Docker with all essential commands and real-world examples.

## 📋 Table of Contents
- [Installation](#installation)
- [Docker Basics](#docker-basics)
- [Working with Images](#working-with-images)
- [Running Containers](#running-containers)
- [Container Management](#container-management)
- [Building Images (Dockerfile)](#building-images-dockerfile)
- [Docker Networking](#docker-networking)
- [Docker Volumes and Storage](#docker-volumes-and-storage)
- [Docker Compose](#docker-compose)
- [Docker Registry](#docker-registry)
- [Container Logs and Debugging](#container-logs-and-debugging)
- [Resource Management](#resource-management)
- [Docker System Management](#docker-system-management)
- [Best Practices](#best-practices)
- [Real-World Examples](#real-world-examples)

---

## Installation

### AlmaLinux / RHEL / Rocky Linux

```bash
# Update system
sudo dnf update -y

# Install required packages
sudo dnf install -y dnf-plugins-core

# Add Docker repository (using CentOS repo for RHEL derivatives)
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Install Docker Engine
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Verify installation
sudo docker --version
sudo docker run hello-world

# Add user to docker group (run without sudo)
sudo usermod -aG docker $USER
newgrp docker

# Verify user can run docker
docker ps
```

### Ubuntu / Debian

```bash
# Update system
sudo apt-get update

# Install prerequisites
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### Verify Installation

```bash
# Check Docker version
docker --version
docker version

# Check Docker info
docker info

# Test with hello-world
docker run hello-world
```

---

## Docker Basics

### Understanding Docker Components

```bash
# Check Docker service status
sudo systemctl status docker

# View Docker system information
docker info

# Check Docker disk usage
docker system df

# Show Docker version details
docker version
```

### Getting Help

```bash
# General help
docker --help

# Help for specific command
docker run --help
docker build --help
docker network --help

# Show Docker command reference
man docker
```

---

## Working with Images

### Searching and Pulling Images

```bash
# Search for images on Docker Hub
docker search nginx
docker search ubuntu
docker search --filter stars=100 nginx

# Pull an image from Docker Hub
docker pull nginx
docker pull nginx:latest
docker pull nginx:1.25
docker pull ubuntu:22.04

# Pull from specific registry
docker pull quay.io/prometheus/prometheus
docker pull gcr.io/google-containers/nginx
```

### Listing Images

```bash
# List all images
docker images
docker image ls

# List images with specific format
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Show all images including intermediate
docker images -a

# Show image digests
docker images --digests

# Filter images
docker images nginx
docker images --filter "dangling=true"
docker images --filter "before=nginx:latest"
```

### Inspecting Images

```bash
# Inspect image details
docker inspect nginx
docker inspect nginx:1.25

# Show image history (layers)
docker history nginx
docker history nginx:latest --no-trunc

# Check image size
docker images nginx --format "{{.Repository}}:{{.Tag}} - {{.Size}}"
```

### Tagging Images

```bash
# Tag an image
docker tag nginx:latest mynginx:v1
docker tag nginx:latest myregistry.com/nginx:v1

# Tag with multiple tags
docker tag nginx:latest mynginx:v1
docker tag nginx:latest mynginx:latest
docker tag nginx:latest mynginx:prod
```

### Removing Images

```bash
# Remove an image
docker rmi nginx:latest
docker image rm nginx:latest

# Remove image by ID
docker rmi 5a3221f0137b

# Force remove (even if container using it)
docker rmi -f nginx:latest

# Remove multiple images
docker rmi nginx:1.25 nginx:1.24

# Remove all unused images
docker image prune

# Remove all images
docker rmi $(docker images -q)

# Remove dangling images (untagged)
docker image prune -a
```

### Saving and Loading Images

```bash
# Save image to tar file
docker save nginx:latest -o nginx.tar
docker save nginx:latest | gzip > nginx.tar.gz

# Load image from tar file
docker load -i nginx.tar
docker load < nginx.tar.gz

# Export container as tar (flattened)
docker export my-container > my-container.tar

# Import tar as image
docker import my-container.tar my-image:latest
```

---

## Running Containers

### Basic Container Operations

```bash
# Run a container (pull + create + start)
docker run nginx

# Run container in detached mode (background)
docker run -d nginx

# Run with custom name
docker run -d --name web nginx

# Run and remove after exit
docker run --rm nginx

# Run interactively with terminal
docker run -it ubuntu bash
docker run -it alpine sh

# Run with specific user
docker run -u 1000:1000 nginx
docker run --user nginx nginx
```

### Port Mapping

```bash
# Map container port to host
docker run -d -p 8080:80 nginx
# Host:8080 -> Container:80

# Map to specific host interface
docker run -d -p 127.0.0.1:8080:80 nginx

# Map multiple ports
docker run -d -p 8080:80 -p 8443:443 nginx

# Random host port
docker run -d -P nginx

# Map UDP port
docker run -d -p 53:53/udp my-dns-server
```

### Environment Variables

```bash
# Set environment variable
docker run -e "ENV=production" nginx

# Set multiple environment variables
docker run -e "ENV=prod" -e "DEBUG=false" nginx

# Read from file
docker run --env-file ./env.list nginx

# Example env.list file content:
# ENV=production
# DEBUG=false
# API_KEY=secret123
```

### Volume Mounts

```bash
# Mount host directory to container
docker run -v /host/path:/container/path nginx

# Mount with read-only
docker run -v /host/path:/container/path:ro nginx

# Mount current directory
docker run -v $(pwd):/app nginx

# Create and use named volume
docker run -v mydata:/data nginx

# Mount specific file
docker run -v /host/config.conf:/etc/nginx/nginx.conf nginx
```

### Working Directory

```bash
# Set working directory
docker run -w /app nginx

# Combined with volume
docker run -v $(pwd):/app -w /app node:18 npm install
```

### Container Networking

```bash
# Run on specific network
docker run --network my-network nginx

# Use host network
docker run --network host nginx

# No network
docker run --network none nginx

# Add host entry
docker run --add-host myserver:192.168.1.100 nginx

# Set hostname
docker run --hostname web01 nginx

# Set DNS servers
docker run --dns 8.8.8.8 --dns 8.8.4.4 nginx
```

### Resource Limits

```bash
# Limit memory
docker run -m 512m nginx
docker run --memory 1g nginx

# Limit CPU
docker run --cpus 2 nginx
docker run --cpus 0.5 nginx

# CPU shares (relative weight)
docker run --cpu-shares 512 nginx

# Set specific CPU cores
docker run --cpuset-cpus 0,1 nginx

# Combined limits
docker run -m 1g --cpus 2 nginx
```

### Restart Policies

```bash
# Always restart
docker run -d --restart always nginx

# Restart on failure
docker run -d --restart on-failure nginx

# Restart on failure with max attempts
docker run -d --restart on-failure:5 nginx

# Restart unless stopped
docker run -d --restart unless-stopped nginx

# Never restart (default)
docker run -d --restart no nginx
```

---

## Container Management

### Listing Containers

```bash
# List running containers
docker ps
docker container ls

# List all containers (including stopped)
docker ps -a
docker container ls -a

# List with specific format
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Show container sizes
docker ps -s

# Show only container IDs
docker ps -q

# Show last created container
docker ps -l

# Show n last created containers
docker ps -n 3

# Filter containers
docker ps --filter "status=running"
docker ps --filter "name=web"
docker ps --filter "ancestor=nginx"
```

### Starting and Stopping

```bash
# Start a stopped container
docker start web
docker start container_id

# Start multiple containers
docker start web db cache

# Stop a running container
docker stop web

# Stop with timeout (default 10s)
docker stop -t 30 web

# Force stop (kill)
docker kill web

# Restart container
docker restart web

# Pause container (freeze)
docker pause web

# Unpause container
docker unpause web
```

### Executing Commands

```bash
# Execute command in running container
docker exec web ls -la

# Execute interactive command
docker exec -it web bash
docker exec -it web sh

# Execute as specific user
docker exec -u root -it web bash

# Execute with environment variable
docker exec -e "VAR=value" web printenv

# Run command in working directory
docker exec -w /app web npm install

# Execute detached command
docker exec -d web tail -f /var/log/nginx/access.log
```

### Viewing Logs

```bash
# View container logs
docker logs web

# Follow log output (like tail -f)
docker logs -f web

# Show last N lines
docker logs --tail 100 web

# Show logs with timestamps
docker logs -t web

# Show logs since specific time
docker logs --since 2024-01-01T00:00:00 web
docker logs --since 10m web

# Show logs until specific time
docker logs --until 2024-01-01T23:59:59 web

# Combined options
docker logs -f --tail 50 -t web
```

### Inspecting Containers

```bash
# Inspect container details
docker inspect web

# Get specific field
docker inspect -f '{{.State.Status}}' web
docker inspect -f '{{.NetworkSettings.IPAddress}}' web
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' web

# Show container processes
docker top web

# Show container port mappings
docker port web

# Show container stats (live)
docker stats web

# Show stats for all containers
docker stats

# Show stats once (no stream)
docker stats --no-stream
```

### Copying Files

```bash
# Copy from container to host
docker cp web:/var/log/nginx/access.log ./access.log
docker cp web:/etc/nginx/nginx.conf ./nginx.conf

# Copy from host to container
docker cp ./index.html web:/usr/share/nginx/html/
docker cp ./configs/ web:/etc/nginx/

# Copy preserving ownership
docker cp -a ./data web:/app/
```

### Container Diffs

```bash
# Show changes to files/directories
docker diff web

# Output format:
# A - Added file/directory
# D - Deleted file/directory
# C - Changed file/directory
```

### Removing Containers

```bash
# Remove stopped container
docker rm web

# Force remove running container
docker rm -f web

# Remove multiple containers
docker rm web db cache

# Remove all stopped containers
docker container prune

# Remove all containers (including running)
docker rm -f $(docker ps -aq)

# Remove containers older than 24 hours
docker container prune --filter "until=24h"
```

### Renaming Containers

```bash
# Rename container
docker rename old-name new-name
docker rename web nginx-web
```

### Attaching to Containers

```bash
# Attach to running container
docker attach web

# Detach without stopping: Ctrl+P, Ctrl+Q

# Attach with no stdin
docker attach --no-stdin web
```

### Waiting for Container

```bash
# Wait until container stops
docker wait web

# Returns exit code
```

---

## Building Images (Dockerfile)

### Basic Dockerfile

```dockerfile
# Example Dockerfile for Python Flask app
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Copy requirements file
COPY requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Expose port
EXPOSE 5000

# Set environment variables
ENV FLASK_APP=app.py
ENV FLASK_ENV=production

# Create non-root user
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:5000/health || exit 1

# Run application
CMD ["python", "app.py"]
```

### Dockerfile Instructions Reference

```dockerfile
# FROM - Base image
FROM ubuntu:22.04
FROM python:3.11-alpine
FROM node:18 AS builder

# LABEL - Metadata
LABEL maintainer="admin@example.com"
LABEL version="1.0"
LABEL description="My application"

# ENV - Environment variables
ENV APP_HOME=/app
ENV PORT=8080
ENV PATH="/app/bin:${PATH}"

# ARG - Build-time variables
ARG VERSION=1.0
ARG BUILD_DATE
RUN echo "Building version ${VERSION}"

# WORKDIR - Set working directory
WORKDIR /app

# COPY - Copy files from host
COPY app.py .
COPY --chown=user:group app.py .
COPY src/ /app/src/

# ADD - Copy and extract (use COPY preferred)
ADD file.tar.gz /app/
ADD https://example.com/file.txt /app/

# RUN - Execute commands
RUN apt-get update && apt-get install -y curl
RUN pip install flask
RUN npm install && npm run build

# RUN with multi-line
RUN apt-get update && \
    apt-get install -y \
        curl \
        wget \
        vim && \
    rm -rf /var/lib/apt/lists/*

# EXPOSE - Document ports
EXPOSE 80
EXPOSE 443
EXPOSE 8080/tcp
EXPOSE 53/udp

# VOLUME - Create mount point
VOLUME /data
VOLUME ["/var/log", "/var/db"]

# USER - Set user
USER appuser
USER 1000
USER appuser:appgroup

# CMD - Default command (can be overridden)
CMD ["python", "app.py"]
CMD python app.py
CMD ["/bin/bash"]

# ENTRYPOINT - Main command (not easily overridden)
ENTRYPOINT ["python", "app.py"]
ENTRYPOINT python app.py

# ENTRYPOINT + CMD (CMD becomes default args)
ENTRYPOINT ["python"]
CMD ["app.py"]

# HEALTHCHECK - Container health check
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -f http://localhost/ || exit 1

# ONBUILD - Trigger for child images
ONBUILD COPY . /app
ONBUILD RUN npm install

# SHELL - Change default shell
SHELL ["/bin/bash", "-c"]

# STOPSIGNAL - Signal to stop container
STOPSIGNAL SIGTERM
```

### Building Images

```bash
# Build image from Dockerfile
docker build -t myapp:latest .

# Build with specific Dockerfile
docker build -f Dockerfile.prod -t myapp:prod .

# Build with build arguments
docker build --build-arg VERSION=1.0 -t myapp:1.0 .

# Build without cache
docker build --no-cache -t myapp:latest .

# Build and tag multiple times
docker build -t myapp:latest -t myapp:v1 -t myapp:prod .

# Build with specific target (multi-stage)
docker build --target builder -t myapp:builder .

# Build with labels
docker build --label version=1.0 --label env=prod -t myapp:latest .

# Show build output
docker build -t myapp:latest . --progress=plain

# Build with specific platform
docker build --platform linux/amd64 -t myapp:latest .
docker build --platform linux/arm64 -t myapp:latest .
```

### Multi-Stage Builds

```dockerfile
# Multi-stage build example (Go application)
# Stage 1: Build
FROM golang:1.21 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/server

# Stage 2: Runtime
FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/server .
EXPOSE 8080
CMD ["./server"]
```

```dockerfile
# Multi-stage build with npm (Node.js)
# Stage 1: Dependencies
FROM node:18 AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Build
FROM node:18 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 3: Runtime
FROM node:18-alpine
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package*.json ./
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

### BuildKit Features

```bash
# Enable BuildKit
export DOCKER_BUILDKIT=1

# Build with BuildKit cache
docker build --cache-from myapp:latest -t myapp:v2 .

# Build with inline cache
docker build --build-arg BUILDKIT_INLINE_CACHE=1 -t myapp:latest .

# Build with secrets (don't expose in layers)
docker build --secret id=mysecret,src=secret.txt -t myapp:latest .

# In Dockerfile:
# RUN --mount=type=secret,id=mysecret \
#     cat /run/secrets/mysecret > /app/secret

# Build with SSH agent forwarding
docker build --ssh default -t myapp:latest .

# In Dockerfile:
# RUN --mount=type=ssh git clone git@github.com:user/repo.git
```

### .dockerignore File

```bash
# Create .dockerignore file
cat > .dockerignore << 'EOF'
# Git files
.git
.gitignore

# Documentation
*.md
README.md
LICENSE

# Development files
.vscode
.idea
*.swp
*.swo

# Dependencies
node_modules
vendor
__pycache__
*.pyc

# Build outputs
dist/
build/
*.log

# Tests
tests/
test/
*.test.js

# Environment files
.env
.env.local
*.key
*.pem

# OS files
.DS_Store
Thumbs.db

# Temporary files
tmp/
temp/
*.tmp
EOF
```

### Dockerfile Best Practices

```dockerfile
# 1. Use specific base image versions
FROM node:18.19.0-alpine
# NOT: FROM node:latest

# 2. Use multi-stage builds
FROM node:18 AS builder
# ... build steps
FROM node:18-alpine
# ... copy artifacts

# 3. Minimize layers - combine RUN commands
RUN apt-get update && \
    apt-get install -y curl wget && \
    rm -rf /var/lib/apt/lists/*

# 4. Order from least to most frequently changing
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .      # Changes less often
RUN pip install -r requirements.txt
COPY . .                     # Changes most often

# 5. Use .dockerignore

# 6. Don't run as root
RUN useradd -m appuser
USER appuser

# 7. Use COPY instead of ADD
COPY app.py .

# 8. Set proper labels
LABEL maintainer="you@example.com" \
      version="1.0.0" \
      description="My application"

# 9. Use specific EXPOSE
EXPOSE 8080/tcp

# 10. Use exec form for CMD/ENTRYPOINT
CMD ["python", "app.py"]
# NOT: CMD python app.py

# 11. Include health checks
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:8080/health || exit 1

# 12. Clean up in same layer
RUN apt-get update && \
    apt-get install -y package && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

---

## Docker Networking

### Network Types

```bash
# Bridge (default) - containers on same host
# Host - use host network stack
# None - no networking
# Overlay - multi-host networking (Swarm)
# Macvlan - assign MAC address to container
```

### Network Management

```bash
# List networks
docker network ls

# Inspect network
docker network inspect bridge

# Create network
docker network create mynetwork

# Create with specific driver
docker network create -d bridge mynetwork

# Create with subnet
docker network create --subnet 172.20.0.0/16 mynetwork

# Create with gateway
docker network create \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  mynetwork

# Create with IP range
docker network create \
  --subnet 172.20.0.0/16 \
  --ip-range 172.20.240.0/20 \
  mynetwork

# Remove network
docker network rm mynetwork

# Remove all unused networks
docker network prune
```

### Connecting Containers to Networks

```bash
# Run container on specific network
docker run -d --network mynetwork --name web nginx

# Connect running container to network
docker network connect mynetwork web

# Disconnect container from network
docker network disconnect mynetwork web

# Connect with specific IP
docker network connect --ip 172.20.0.10 mynetwork web

# Connect with alias
docker network connect --alias webserver mynetwork web
```

### Container Communication

```bash
# Create network
docker network create myapp-network

# Run backend container
docker run -d \
  --name backend \
  --network myapp-network \
  my-backend:latest

# Run frontend container (can reach backend by name)
docker run -d \
  --name frontend \
  --network myapp-network \
  -e BACKEND_URL=http://backend:8080 \
  my-frontend:latest

# Test connectivity
docker exec frontend ping backend
docker exec frontend curl http://backend:8080
```

### DNS and Service Discovery

```bash
# Containers on same network can resolve by name
docker run -d --name web --network mynet nginx
docker run --network mynet --rm alpine ping web

# Add custom DNS servers
docker run --dns 8.8.8.8 --dns 8.8.4.4 nginx

# Add host entries
docker run --add-host api.local:192.168.1.100 nginx

# Set hostname
docker run --hostname web01 nginx

# Set domain name
docker run --domainname example.com nginx
```

### Port Publishing

```bash
# Publish single port
docker run -p 8080:80 nginx

# Publish to specific interface
docker run -p 127.0.0.1:8080:80 nginx

# Publish multiple ports
docker run -p 80:80 -p 443:443 nginx

# Publish all exposed ports to random host ports
docker run -P nginx

# View published ports
docker port nginx
```

### Host Networking

```bash
# Use host network (no isolation)
docker run --network host nginx

# Container uses host's network stack directly
# No port mapping needed
# Ports bind directly to host
```

### Network Troubleshooting

```bash
# Inspect network
docker network inspect bridge

# Check container IP
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' web

# List containers on network
docker network inspect mynetwork -f '{{range .Containers}}{{.Name}} {{end}}'

# Test connectivity
docker exec web ping db
docker exec web curl http://api:8080
docker exec web nslookup api

# Install tools in container for troubleshooting
docker exec -it web sh
# Then: ping, curl, wget, telnet, nc (netcat)
```

---

## Docker Volumes and Storage

### Volume Types

```bash
# Named volumes (managed by Docker)
# Anonymous volumes (managed by Docker, no name)
# Bind mounts (host directory)
# tmpfs mounts (in-memory, Linux only)
```

### Volume Management

```bash
# List volumes
docker volume ls

# Create volume
docker volume create mydata

# Create with options
docker volume create \
  --driver local \
  --opt type=nfs \
  --opt o=addr=192.168.1.1,rw \
  --opt device=:/path/to/dir \
  nfs-volume

# Inspect volume
docker volume inspect mydata

# Remove volume
docker volume rm mydata

# Remove all unused volumes
docker volume prune

# Remove with filter
docker volume prune --filter "label=temporary"
```

### Using Volumes

```bash
# Named volume
docker run -v mydata:/data nginx

# Anonymous volume
docker run -v /data nginx

# Bind mount (host directory)
docker run -v /host/path:/container/path nginx
docker run -v $(pwd):/app nginx

# Read-only mount
docker run -v mydata:/data:ro nginx

# Multiple volumes
docker run \
  -v data:/var/lib/mysql \
  -v logs:/var/log/mysql \
  mysql:8.0

# Volume from another container
docker run --volumes-from db-container web-container
```

### Bind Mounts

```bash
# Mount current directory
docker run -v $(pwd):/app node:18 npm install

# Mount specific file
docker run -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro nginx

# Mount with specific ownership (using :z or :Z for SELinux)
docker run -v $(pwd):/app:z nginx

# Mount as read-only
docker run -v /host/config:/config:ro nginx
```

### tmpfs Mounts (Linux)

```bash
# Create tmpfs mount (memory-based, temporary)
docker run --tmpfs /app/tmp nginx

# With size limit
docker run --tmpfs /app/tmp:rw,size=100m nginx

# Use mount flag
docker run --mount type=tmpfs,destination=/app/tmp,tmpfs-size=100m nginx
```

### Advanced Mount Options

```bash
# Using --mount (more explicit)
docker run --mount type=volume,source=mydata,target=/data nginx

# Bind mount with --mount
docker run --mount type=bind,source=$(pwd),target=/app nginx

# Read-only bind mount
docker run --mount type=bind,source=$(pwd),target=/app,readonly nginx

# tmpfs with --mount
docker run --mount type=tmpfs,destination=/tmp,tmpfs-size=100m nginx
```

### Volume Backup and Restore

```bash
# Backup volume to tar file
docker run --rm \
  -v mydata:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/mydata-backup.tar.gz -C /data .

# Restore volume from tar file
docker run --rm \
  -v mydata:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/mydata-backup.tar.gz -C /data

# Copy volume data between volumes
docker run --rm \
  -v source-volume:/from \
  -v target-volume:/to \
  alpine sh -c "cp -av /from/* /to/"
```

### Inspecting Volume Usage

```bash
# Show volume details
docker volume inspect mydata

# Show size and usage
docker system df -v

# Find containers using a volume
docker ps -a --filter volume=mydata

# Find which container created anonymous volume
docker inspect <container> | grep -A 10 Mounts
```

---

## Docker Compose

### Installation Check

```bash
# Check if docker compose is installed
docker compose version

# Old docker-compose (v1) - legacy
docker-compose --version
```

### Basic docker-compose.yml

```yaml
version: '3.8'

services:
  web:
    image: nginx:latest
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html
    environment:
      - NGINX_HOST=localhost
      - NGINX_PORT=80
    restart: unless-stopped

  db:
    image: postgres:15
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
    volumes:
      - db-data:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  db-data:
```

### Compose Commands

```bash
# Start services (creates and starts containers)
docker compose up

# Start in detached mode
docker compose up -d

# Start specific service
docker compose up web

# Build images before starting
docker compose up --build

# Force recreate containers
docker compose up --force-recreate

# Start with specific compose file
docker compose -f docker-compose.prod.yml up -d

# Scale services
docker compose up -d --scale web=3

# Stop services
docker compose stop

# Stop specific service
docker compose stop web

# Start stopped services
docker compose start

# Restart services
docker compose restart

# Restart specific service
docker compose restart web

# Pause services
docker compose pause

# Unpause services
docker compose unpause

# Stop and remove containers, networks
docker compose down

# Stop and remove with volumes
docker compose down -v

# Stop and remove with images
docker compose down --rmi all

# View logs
docker compose logs

# Follow logs
docker compose logs -f

# Logs for specific service
docker compose logs web

# Last 100 lines
docker compose logs --tail 100

# List containers
docker compose ps

# List all (including stopped)
docker compose ps -a

# Execute command in service
docker compose exec web bash
docker compose exec db psql -U user -d myapp

# Run one-off command
docker compose run web ls -la

# View service config
docker compose config

# Validate compose file
docker compose config -q

# Build services
docker compose build

# Build specific service
docker compose build web

# Build without cache
docker compose build --no-cache

# Pull images
docker compose pull

# Push images
docker compose push

# View processes
docker compose top
```

### Complete docker-compose.yml Example

```yaml
version: '3.8'

services:
  # Frontend service
  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
      args:
        NODE_ENV: production
    image: myapp-frontend:latest
    container_name: frontend
    ports:
      - "3000:3000"
    environment:
      - API_URL=http://backend:8080
      - NODE_ENV=production
    env_file:
      - ./frontend/.env
    volumes:
      - ./frontend/src:/app/src:ro
      - node_modules:/app/node_modules
    depends_on:
      - backend
    networks:
      - frontend-net
      - backend-net
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 3s
      retries: 3

  # Backend service
  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
      target: production
    image: myapp-backend:latest
    container_name: backend
    ports:
      - "8080:8080"
    environment:
      - DATABASE_URL=postgresql://user:password@db:5432/myapp
      - REDIS_URL=redis://redis:6379
    volumes:
      - ./backend/uploads:/app/uploads
      - backend-logs:/app/logs
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - backend-net
      - db-net
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M

  # Database service
  db:
    image: postgres:15-alpine
    container_name: postgres-db
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
    volumes:
      - db-data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    networks:
      - db-net
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user -d myapp"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Redis cache
  redis:
    image: redis:7-alpine
    container_name: redis-cache
    command: redis-server --requirepass password
    volumes:
      - redis-data:/data
    networks:
      - backend-net
    restart: unless-stopped

  # Nginx reverse proxy
  nginx:
    image: nginx:alpine
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
      - nginx-logs:/var/log/nginx
    depends_on:
      - frontend
      - backend
    networks:
      - frontend-net
    restart: unless-stopped

networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge
  db-net:
    driver: bridge

volumes:
  db-data:
  redis-data:
  backend-logs:
  nginx-logs:
  node_modules:
```

### Multiple Compose Files

```bash
# Use multiple compose files (override pattern)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# docker-compose.yml (base)
# docker-compose.override.yml (automatically applied)
# docker-compose.prod.yml (production overrides)

# Example override:
# docker-compose.override.yml
version: '3.8'
services:
  web:
    volumes:
      - ./src:/app/src  # Enable hot reload for development
    command: npm run dev
```

### Environment Variables in Compose

```bash
# Use .env file (automatically loaded)
# .env file:
POSTGRES_VERSION=15
APP_PORT=8080

# docker-compose.yml:
services:
  db:
    image: postgres:${POSTGRES_VERSION}
  web:
    ports:
      - "${APP_PORT}:8080"

# Use shell environment variables
export APP_ENV=production
docker compose up -d
```

---

## Docker Registry

### Docker Hub

```bash
# Login to Docker Hub
docker login

# Login with credentials
docker login -u username -p password

# Logout
docker logout

# Tag image for Docker Hub
docker tag myapp:latest username/myapp:latest
docker tag myapp:latest username/myapp:v1.0

# Push to Docker Hub
docker push username/myapp:latest
docker push username/myapp:v1.0

# Pull from Docker Hub
docker pull username/myapp:latest

# Search Docker Hub
docker search nginx
docker search --filter stars=100 nginx
```

### Private Registry

```bash
# Run local registry
docker run -d -p 5000:5000 --name registry registry:2

# Tag for private registry
docker tag myapp:latest localhost:5000/myapp:latest

# Push to private registry
docker push localhost:5000/myapp:latest

# Pull from private registry
docker pull localhost:5000/myapp:latest

# List images in registry
curl http://localhost:5000/v2/_catalog

# Run secure registry with TLS
docker run -d \
  -p 5000:5000 \
  --name registry \
  -v $(pwd)/certs:/certs \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  registry:2

# Run registry with authentication
docker run -d \
  -p 5000:5000 \
  --name registry \
  -v $(pwd)/auth:/auth \
  -e "REGISTRY_AUTH=htpasswd" \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
  registry:2

# Create htpasswd file
docker run --rm \
  --entrypoint htpasswd \
  registry:2 -Bbn username password > auth/htpasswd
```

### Other Registries

```bash
# AWS ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com

docker tag myapp:latest 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:latest
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:latest

# Google Container Registry (GCR)
gcloud auth configure-docker
docker tag myapp:latest gcr.io/project-id/myapp:latest
docker push gcr.io/project-id/myapp:latest

# Azure Container Registry (ACR)
az acr login --name myregistry
docker tag myapp:latest myregistry.azurecr.io/myapp:latest
docker push myregistry.azurecr.io/myapp:latest

# Quay.io
docker login quay.io
docker tag myapp:latest quay.io/username/myapp:latest
docker push quay.io/username/myapp:latest

# Harbor
docker login harbor.example.com
docker tag myapp:latest harbor.example.com/project/myapp:latest
docker push harbor.example.com/project/myapp:latest
```

---

## Container Logs and Debugging

### Viewing Logs

```bash
# View container logs
docker logs web

# Follow logs
docker logs -f web

# Show timestamps
docker logs -t web

# Show last N lines
docker logs --tail 50 web

# Show logs since timestamp
docker logs --since 2024-01-01T00:00:00 web
docker logs --since 1h web
docker logs --since 30m web

# Show logs until timestamp
docker logs --until 2024-01-01T23:59:59 web

# Combined options
docker logs -f --tail 100 --since 10m web
```

### Debugging Containers

```bash
# Access container shell
docker exec -it web bash
docker exec -it web sh

# Run as root user
docker exec -u root -it web bash

# Check processes
docker top web
docker exec web ps aux

# Check resource usage
docker stats web
docker stats --no-stream

# Inspect container
docker inspect web
docker inspect web | grep -i ipaddress

# Check container changes
docker diff web

# View container events
docker events
docker events --filter container=web
docker events --since 1h

# Export filesystem
docker export web > web-filesystem.tar

# Check container health
docker inspect --format='{{.State.Health.Status}}' web
```

### Troubleshooting Commands

```bash
# Container won't start - check logs
docker logs container-name

# Check why container stopped
docker inspect --format='{{.State.ExitCode}}' container-name
docker inspect --format='{{.State.Error}}' container-name

# Test network connectivity
docker exec web ping db
docker exec web curl http://api:8080
docker exec web nslookup api

# Check DNS resolution
docker exec web cat /etc/resolv.conf

# Check environment variables
docker exec web env
docker exec web printenv

# Check mounted volumes
docker inspect -f '{{.Mounts}}' web

# Check port mappings
docker port web

# Live attach to container output
docker attach web

# Copy files for inspection
docker cp web:/var/log/app.log ./app.log

# Run commands for debugging
docker exec web ls -la /app
docker exec web cat /etc/nginx/nginx.conf
docker exec web df -h
docker exec web free -m
```

### Installing Debug Tools

```bash
# Alpine-based containers
docker exec web apk add curl wget bind-tools

# Debian/Ubuntu-based containers
docker exec web apt-get update && apt-get install -y curl wget dnsutils iputils-ping

# RHEL-based containers
docker exec web yum install -y curl wget bind-utils iputils
```

### Debug Container Pattern

```bash
# Run debug container on same network
docker run -it --network container:web alpine sh

# Run debug container with same volumes
docker run -it \
  --volumes-from web \
  alpine sh

# Debug with network tools
docker run -it --rm \
  --network mynetwork \
  nicolaka/netshoot

# Common debug commands in netshoot:
# ping, curl, wget, netstat, ss, nslookup, dig, tcpdump, iperf
```

---

## Resource Management

### CPU Limits

```bash
# Limit to specific number of CPUs
docker run --cpus 2 nginx
docker run --cpus 0.5 nginx

# CPU shares (relative weight)
docker run --cpu-shares 512 nginx
# Default is 1024

# Restrict to specific CPU cores
docker run --cpuset-cpus 0,1 nginx
docker run --cpuset-cpus 0-3 nginx

# CPU quota (microseconds per period)
docker run --cpu-period 100000 --cpu-quota 50000 nginx
# 50% of one CPU
```

### Memory Limits

```bash
# Memory limit
docker run -m 512m nginx
docker run --memory 1g nginx

# Memory + swap limit
docker run -m 512m --memory-swap 1g nginx

# Memory reservation (soft limit)
docker run --memory-reservation 256m nginx

# Disable OOM killer
docker run -m 512m --oom-kill-disable nginx

# OOM score adjustment
docker run --oom-score-adj 500 nginx
```

### Disk I/O Limits

```bash
# Block IO weight
docker run --blkio-weight 500 nginx
# Default is 500, range 10-1000

# Limit read rate
docker run --device-read-bps /dev/sda:10mb nginx

# Limit write rate
docker run --device-write-bps /dev/sda:5mb nginx

# Limit read IOPS
docker run --device-read-iops /dev/sda:1000 nginx

# Limit write IOPS
docker run --device-write-iops /dev/sda:500 nginx
```

### Combined Resource Limits

```bash
# Production container with limits
docker run -d \
  --name web \
  -m 1g \
  --memory-reservation 512m \
  --cpus 2 \
  --cpuset-cpus 0-3 \
  --restart unless-stopped \
  nginx:latest

# Resource constraints in docker-compose.yml
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M
```

### Monitoring Resources

```bash
# Real-time stats
docker stats

# Stats for specific container
docker stats web

# No streaming (one snapshot)
docker stats --no-stream

# Format output
docker stats --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Check resource limits
docker inspect -f '{{.HostConfig.Memory}}' web
docker inspect -f '{{.HostConfig.NanoCpus}}' web
```

---

## Docker System Management

### System Information

```bash
# Docker system info
docker info

# Docker version
docker version

# Docker disk usage
docker system df

# Detailed disk usage
docker system df -v

# System events
docker events

# Filter events
docker events --filter 'type=container'
docker events --filter 'event=start'
docker events --since 1h
```

### Cleanup Commands

```bash
# Remove stopped containers
docker container prune

# Remove unused images
docker image prune

# Remove all unused images (not just dangling)
docker image prune -a

# Remove unused volumes
docker volume prune

# Remove unused networks
docker network prune

# Remove all unused objects
docker system prune

# Remove everything (nuclear option)
docker system prune -a --volumes

# Remove with filter
docker image prune --filter "until=24h"
docker container prune --filter "until=72h"

# Confirm prompts automatically
docker system prune -f
```

### Specific Cleanup

```bash
# Remove all stopped containers
docker rm $(docker ps -aq -f status=exited)

# Remove containers older than 24 hours
docker container prune --filter "until=24h"

# Remove dangling images
docker rmi $(docker images -f "dangling=true" -q)

# Remove all images
docker rmi $(docker images -q)

# Remove all volumes not used by containers
docker volume rm $(docker volume ls -q)

# Remove specific pattern
docker images | grep "myapp" | awk '{print $3}' | xargs docker rmi
```

### Export and Import

```bash
# Save image to tar
docker save nginx:latest -o nginx.tar
docker save nginx:latest | gzip > nginx.tar.gz

# Load image from tar
docker load -i nginx.tar
docker load < nginx.tar.gz

# Export container filesystem
docker export my-container -o container.tar

# Import as image
docker import container.tar my-image:latest
cat container.tar | docker import - my-image:latest
```

### Docker Context

```bash
# List contexts
docker context ls

# Create context (for remote Docker host)
docker context create remote --docker "host=ssh://user@remote-host"

# Use context
docker context use remote

# Switch back to default
docker context use default

# Inspect context
docker context inspect remote

# Remove context
docker context rm remote
```

### Configuration

```bash
# Docker daemon config
cat /etc/docker/daemon.json

# Example daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-address-pools": [
    {
      "base": "172.17.0.0/16",
      "size": 24
    }
  ]
}

# Reload daemon after config change
sudo systemctl reload docker
sudo systemctl restart docker
```

---

## Best Practices

### Security Best Practices

```bash
# 1. Don't run as root
RUN useradd -m appuser
USER appuser

# 2. Use minimal base images
FROM alpine:3.19
FROM python:3.11-slim
FROM gcr.io/distroless/python3

# 3. Scan images for vulnerabilities
docker scan nginx:latest
trivy image nginx:latest

# 4. Use specific image versions
FROM nginx:1.25.3
# NOT: FROM nginx:latest

# 5. Drop unnecessary capabilities
docker run --cap-drop ALL --cap-add NET_BIND_SERVICE nginx

# 6. Use read-only filesystem
docker run --read-only nginx

# 7. Set resource limits
docker run -m 512m --cpus 1 nginx

# 8. Use secrets management
docker secret create my-secret secret.txt
docker service create --secret my-secret nginx

# 9. Enable user namespace remapping
# In /etc/docker/daemon.json:
{
  "userns-remap": "default"
}

# 10. Use security profiles
docker run --security-opt seccomp=profile.json nginx
docker run --security-opt apparmor=docker-default nginx
```

### Performance Best Practices

```bash
# 1. Use .dockerignore
# Reduces build context size

# 2. Multi-stage builds
# Keeps final image small

# 3. Order Dockerfile instructions by change frequency
# Most stable instructions first

# 4. Combine RUN commands
RUN apt-get update && \
    apt-get install -y package && \
    rm -rf /var/lib/apt/lists/*

# 5. Use BuildKit
export DOCKER_BUILDKIT=1

# 6. Use caching effectively
# Copy dependency files before source code

# 7. Clean up in same layer
RUN wget http://example.com/big-file && \
    process-file && \
    rm big-file

# 8. Use alpine or distroless images
FROM alpine:3.19
FROM gcr.io/distroless/base

# 9. Optimize logging
docker run --log-opt max-size=10m --log-opt max-file=3 nginx

# 10. Use volumes for data
# Don't store data in container layer
```

### Operational Best Practices

```bash
# 1. Use health checks
HEALTHCHECK CMD curl -f http://localhost/ || exit 1

# 2. Set restart policies
docker run --restart unless-stopped nginx

# 3. Use labels for organization
docker run -l env=prod -l team=backend nginx

# 4. Implement logging strategy
docker run --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  nginx

# 5. Monitor resource usage
docker stats

# 6. Use Docker Compose for multi-container apps
docker compose up -d

# 7. Tag images meaningfully
docker tag myapp:latest myapp:v1.2.3
docker tag myapp:latest myapp:$(git rev-parse --short HEAD)

# 8. Regular cleanup
docker system prune -a --volumes

# 9. Use networks for container communication
docker network create myapp-net
docker run --network myapp-net nginx

# 10. Backup volumes regularly
docker run --rm -v mydata:/data -v $(pwd):/backup \
  alpine tar czf /backup/backup.tar.gz -C /data .
```

---

## Real-World Examples

### Example 1: Simple Web Application

```bash
# Project structure
myapp/
├── Dockerfile
├── app.py
├── requirements.txt
└── templates/
    └── index.html

# Dockerfile
cat > Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
EOF

# Build and run
docker build -t myapp:latest .
docker run -d -p 5000:5000 --name myapp myapp:latest

# Check logs
docker logs -f myapp

# Access application
curl http://localhost:5000
```

### Example 2: WordPress with MySQL

```yaml
# docker-compose.yml
version: '3.8'

services:
  wordpress:
    image: wordpress:latest
    ports:
      - "8080:80"
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: wordpress
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - wordpress-data:/var/www/html
    depends_on:
      - db
    restart: unless-stopped

  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: wordpress
    volumes:
      - db-data:/var/lib/mysql
    restart: unless-stopped

volumes:
  wordpress-data:
  db-data:
```

```bash
# Run
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f

# Access WordPress
# Open browser: http://localhost:8080

# Backup
docker compose exec db mysqldump -u wordpress -pwordpress wordpress > backup.sql

# Restore
docker compose exec -T db mysql -u wordpress -pwordpress wordpress < backup.sql

# Stop
docker compose down

# Stop and remove volumes
docker compose down -v
```

### Example 3: Microservices Application

```yaml
# docker-compose.yml
version: '3.8'

services:
  frontend:
    build: ./frontend
    ports:
      - "3000:3000"
    environment:
      - API_URL=http://localhost:8080
    depends_on:
      - backend
    networks:
      - frontend-net

  backend:
    build: ./backend
    ports:
      - "8080:8080"
    environment:
      - DB_HOST=postgres
      - REDIS_HOST=redis
    depends_on:
      - postgres
      - redis
    networks:
      - frontend-net
      - backend-net

  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - backend-net

  redis:
    image: redis:7-alpine
    volumes:
      - redis-data:/data
    networks:
      - backend-net

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - frontend
      - backend
    networks:
      - frontend-net

networks:
  frontend-net:
  backend-net:

volumes:
  postgres-data:
  redis-data:
```

### Example 4: Development Environment

```yaml
# docker-compose.dev.yml
version: '3.8'

services:
  app:
    build:
      context: .
      target: development
    volumes:
      - .:/app
      - /app/node_modules
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=development
    command: npm run dev

  db:
    image: postgres:15-alpine
    ports:
      - "5432:5432"
    environment:
      POSTGRES_DB: devdb
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: dev
    volumes:
      - dev-db:/var/lib/postgresql/data

volumes:
  dev-db:
```

```bash
# Run development environment
docker compose -f docker-compose.dev.yml up

# Hot reload enabled via volume mount
# Database accessible on localhost:5432
```

### Example 5: CI/CD Pipeline

```bash
# Build script (build.sh)
#!/bin/bash

# Build image
docker build -t myapp:${VERSION} .

# Run tests
docker run --rm myapp:${VERSION} npm test

# Tag for registry
docker tag myapp:${VERSION} registry.example.com/myapp:${VERSION}
docker tag myapp:${VERSION} registry.example.com/myapp:latest

# Push to registry
docker push registry.example.com/myapp:${VERSION}
docker push registry.example.com/myapp:latest

# Clean up
docker image prune -f
```

---

## Quick Reference Cheat Sheet

```bash
# ==================== IMAGES ====================
docker images                    # List images
docker pull nginx                # Pull image
docker build -t myapp .          # Build image
docker rmi nginx                 # Remove image
docker tag nginx mynginx:v1      # Tag image
docker save nginx > nginx.tar    # Save image
docker load < nginx.tar          # Load image

# ==================== CONTAINERS ====================
docker ps                        # List running containers
docker ps -a                     # List all containers
docker run -d nginx              # Run container (detached)
docker run -it ubuntu bash       # Run interactive
docker exec -it web bash         # Execute command
docker start web                 # Start container
docker stop web                  # Stop container
docker restart web               # Restart container
docker rm web                    # Remove container
docker logs -f web               # Follow logs
docker inspect web               # Inspect container
docker stats web                 # Resource stats

# ==================== NETWORKS ====================
docker network ls                # List networks
docker network create mynet      # Create network
docker network connect mynet web # Connect container
docker network inspect mynet     # Inspect network

# ==================== VOLUMES ====================
docker volume ls                 # List volumes
docker volume create mydata      # Create volume
docker volume inspect mydata     # Inspect volume
docker volume rm mydata          # Remove volume

# ==================== COMPOSE ====================
docker compose up -d             # Start services
docker compose down              # Stop services
docker compose logs -f           # Follow logs
docker compose ps                # List services
docker compose exec web bash     # Execute command

# ==================== CLEANUP ====================
docker system prune              # Remove unused data
docker system prune -a --volumes # Remove all unused
docker container prune           # Remove stopped containers
docker image prune               # Remove unused images
docker volume prune              # Remove unused volumes

# ==================== REGISTRY ====================
docker login                     # Login to registry
docker push username/image       # Push image
docker pull username/image       # Pull image

# ==================== SYSTEM ====================
docker info                      # System information
docker version                   # Docker version
docker system df                 # Disk usage
```

---

## Additional Resources

### Official Documentation
- [Docker Documentation](https://docs.docker.com/)
- [Dockerfile Reference](https://docs.docker.com/engine/reference/builder/)
- [Docker Compose Reference](https://docs.docker.com/compose/compose-file/)
- [Docker CLI Reference](https://docs.docker.com/engine/reference/commandline/cli/)

### Related Documentation
- [Docker and Container Orchestration](docker-and-orchestration.md)
- [Understanding Containers](containers.md)
- [Container Runtime](container-runtime.md)
- [Kubernetes Installation Requirements](k8s-installation-requirements.md)

### Learning Resources
- [Docker Hub](https://hub.docker.com/)
- [Docker Samples](https://github.com/dockersamples)
- [Play with Docker](https://labs.play-with-docker.com/)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)

---

**🎯 Next Steps:**
1. Install Docker on your system
2. Run the examples in this guide
3. Build your own Docker images
4. Learn Docker Compose for multi-container applications
5. Move to [Kubernetes](what-is-kubernetes.md) for container orchestration

**💡 Practice Tips:**
- Start with simple containers (nginx, alpine)
- Practice building Dockerfiles
- Experiment with networking between containers
- Use Docker Compose for realistic applications
- Learn to troubleshoot common issues
- Always clean up unused resources
