#!/bin/bash

# Get DNS domain from hostname
if [ -z "$dnsbinder_domain" ]; then
    dnsbinder_domain=$(hostname -d)
    if [ -z "$dnsbinder_domain" ]; then
        echo "Error: Could not determine DNS domain from hostname."
        echo "Please set dnsbinder_domain environment variable or configure FQDN hostname."
        exit 1
    fi
fi

echo "Using DNS domain: ${dnsbinder_domain}"

# Install nginx and nginx-mod-stream if not present
if ! command -v nginx &> /dev/null; then
    echo "Installing nginx..."
    sudo dnf install -y nginx
fi

if ! rpm -q nginx-mod-stream &> /dev/null; then
    echo "Installing nginx-mod-stream..."
    sudo dnf install -y nginx-mod-stream
fi

# Enable nginx service if not already enabled
if ! sudo systemctl is-enabled nginx &> /dev/null; then
    echo "Enabling nginx service..."
    sudo systemctl enable nginx
fi

# Start nginx service if not already running
if ! sudo systemctl is-active nginx &> /dev/null; then
    echo "Starting nginx service..."
    sudo systemctl start nginx
fi

# Disable default HTTP server block if present
if grep -q "^\s*server\s*{" /etc/nginx/nginx.conf && grep -q "listen.*80" /etc/nginx/nginx.conf; then
    echo "Disabling default HTTP server block in nginx.conf..."
    sudo sed -i '/^\s*server\s*{/,/^\s*}/s/^/#/' /etc/nginx/nginx.conf
fi

echo "=== Nginx Load Balancer Setup ==="
echo "1) Kubernetes HA Control Plane (API Server)"
echo "2) NodePort Service Load Balancer"
read -p "Select setup type [1-2]: " SETUP_TYPE

case $SETUP_TYPE in
    1)
        ENDPOINT_NAME="k8s-cp"
        PORT_NUMBER=6443
        BACKEND_PREFIX="k8s-cp"
        echo "Setting up K8s HA Control Plane load balancer..."
        read -p "Enter the endpoint name (default: k8s-cp): " INPUT_ENDPOINT
        ENDPOINT_NAME=${INPUT_ENDPOINT:-$ENDPOINT_NAME}
        read -p "Enter the API server port (default: 6443): " INPUT_PORT
        PORT_NUMBER=${INPUT_PORT:-$PORT_NUMBER}
        BACKEND_PORT=$PORT_NUMBER
        ;;
    2)
        echo "Setting up NodePort Service load balancer..."
        read -p "Enter the service endpoint name (e.g., my-app-svc): " ENDPOINT_NAME
        ENDPOINT_NAME=${ENDPOINT_NAME:-my-app-svc}
        read -p "Enter the listen port for clients (e.g., 80, 443): " LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-80}
        read -p "Enter the NodePort number (30000-32767): " BACKEND_PORT
        BACKEND_PORT=${BACKEND_PORT:-30080}
        PORT_NUMBER=$LISTEN_PORT
        BACKEND_PREFIX="k8s-w"
        ;;
    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac

# Check if dnsbinder is available
HAS_DNSBINDER=false
if command -v dnsbinder &> /dev/null; then
    HAS_DNSBINDER=true
fi

# Discover backend nodes by checking DNS records
echo "Discovering backend nodes..."
BACKEND_NODES=()
for i in {1..10}; do
    NODE_NAME="${BACKEND_PREFIX}${i}"
    if getent hosts ${NODE_NAME}.${dnsbinder_domain} &> /dev/null; then
        BACKEND_NODES+=("${NODE_NAME}")
        echo "  Found: ${NODE_NAME}.${dnsbinder_domain}"
    fi
done

# Check if we found any backend nodes
if [ ${#BACKEND_NODES[@]} -eq 0 ]; then
    echo "Error: No backend nodes found with pattern ${BACKEND_PREFIX}[1-10].${dnsbinder_domain}"
    exit 1
fi

echo "Total backend nodes found: ${#BACKEND_NODES[@]}"

# Create CNAME for endpoint pointing to this load balancer server
CNAME_FQDN="${ENDPOINT_NAME}.${dnsbinder_domain}"
if getent hosts ${CNAME_FQDN} &> /dev/null; then
    echo "DNS record for ${CNAME_FQDN} already exists."
else
    if [ "$HAS_DNSBINDER" = true ]; then
        echo "Creating CNAME record: ${CNAME_FQDN} -> $(hostname -f)"
        sudo dnsbinder -cc ${CNAME_FQDN} $(hostname -f)
        # Flush DNS cache to clear negative cache entry
        if command -v resolvectl &> /dev/null; then
            sudo resolvectl flush-caches &> /dev/null
        fi
    else
        echo "Error: DNS record for ${CNAME_FQDN} does not exist."
        echo "Please create it from the lab infra server using:"
        echo "  sudo dnsbinder -cc ${CNAME_FQDN} $(hostname -f)"
        exit 1
    fi
fi

# Add stream.d include to nginx.conf if not already present
if ! grep 'stream.d' /etc/nginx/nginx.conf; then
	echo 'include /etc/nginx/stream.d/*.conf;' | sudo tee -a /etc/nginx/nginx.conf  
fi

# Create stream.d directory
sudo mkdir -p /etc/nginx/stream.d

# Get the IPv4 address of this server
SERVER_IPV4=$(hostname -I | awk '{print $1}')
if [ -z "$SERVER_IPV4" ]; then
    echo "Error: Could not determine server IPv4 address"
    exit 1
fi

echo "Using server IP address: ${SERVER_IPV4}"

# Generate nginx stream configuration file dynamically
UPSTREAM_NAME="${ENDPOINT_NAME//-/_}_upstream"
LOG_FORMAT_NAME="${ENDPOINT_NAME//-/_}_tcp"

# Build upstream servers dynamically
UPSTREAM_SERVERS=""
for node in "${BACKEND_NODES[@]}"; do
    UPSTREAM_SERVERS="${UPSTREAM_SERVERS}        server ${node}.${dnsbinder_domain}:${BACKEND_PORT} max_fails=3 fail_timeout=30s;\n"
done

sudo tee /etc/nginx/stream.d/${ENDPOINT_NAME}.conf > /dev/null <<EOF
stream {

    log_format ${LOG_FORMAT_NAME} '\$remote_addr [\$time_local] ' '\$protocol \$status \$bytes_sent bytes sent ' 'to \$upstream_addr';

    upstream ${UPSTREAM_NAME} {
$(echo -e "$UPSTREAM_SERVERS")    }

    server {
        listen ${SERVER_IPV4}:${PORT_NUMBER};
        proxy_pass ${UPSTREAM_NAME};

        access_log /var/log/nginx/${ENDPOINT_NAME}_tcp_access.log ${LOG_FORMAT_NAME};
        error_log  /var/log/nginx/${ENDPOINT_NAME}_tcp_error.log info;
    }
}
EOF

echo "Configuration created at /etc/nginx/stream.d/${ENDPOINT_NAME}.conf"

# Reload nginx
sudo systemctl reload nginx

echo "Nginx load balancer setup complete!"
echo "Endpoint: ${ENDPOINT_NAME}.${dnsbinder_domain}:${PORT_NUMBER}"
