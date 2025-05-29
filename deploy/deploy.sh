#!/bin/bash

# Usage: ./deploy.sh <docker_image_tag> <domain>
# Example: ./deploy.sh saravanakr/langflow:1.4.2 demo-aiagentsbuilder.duckdns.org

set -e

DOCKER_IMAGE="$1"
DOMAIN="$2"

if [ -z "$DOCKER_IMAGE" ] || [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <docker_image_tag> <domain>"
    exit 1
fi

echo "==> Installing required packages if missing..."

install_if_missing() {
    PKG="$1"
    if ! dpkg -s "$PKG" >/dev/null 2>&1; then
        echo "Installing $PKG..."
        apt-get install -y "$PKG"
    else
        echo "$PKG is already installed."
    fi
}

apt-get update

install_if_missing docker.io
install_if_missing nginx
install_if_missing certbot
install_if_missing python3-certbot-nginx
install_if_missing curl

echo "==> Enabling and starting Docker..."
systemctl enable docker
systemctl start docker

echo "==> Pulling Docker image: $DOCKER_IMAGE"
docker pull "$DOCKER_IMAGE"

echo "==> Finding all running Docker containers..."

CONTAINERS=$(docker ps -q)

if [ -n "$CONTAINERS" ]; then
    echo "==> Stopping all running containers:"
    echo "$CONTAINERS"
    docker stop $CONTAINERS

    echo "==> Removing all stopped containers:"
    docker rm $CONTAINERS
else
    echo "==> No running containers found."
fi

echo "==> Running Docker container on port 7860..."
docker run -d --restart unless-stopped --name app -p 7860:7860 "$DOCKER_IMAGE"

echo "==> Setting up NGINX reverse proxy for $DOMAIN..."
cat > /etc/nginx/sites-available/langflow <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:7860;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/langflow /etc/nginx/sites-enabled/langflow

echo "==> Testing NGINX configuration..."
nginx -t

echo "==> Ensuring NGINX service is running..."
if systemctl is-active --quiet nginx; then
    echo "NGINX is running, reloading..."
    systemctl reload nginx
else
    echo "NGINX is not running, starting it..."
    systemctl start nginx
fi

echo "==> Requesting HTTPS certificate for $DOMAIN..."
certbot --nginx --non-interactive --agree-tos --redirect -d "$DOMAIN" -m admin@$DOMAIN

echo "==> Verifying Certbot automatic renewal..."
if systemctl list-timers --all | grep -q certbot; then
    echo "✅ Certbot auto-renewal timer is active."
else
    echo "❌ Certbot auto-renewal timer is NOT active!"
    exit 1
fi

echo "==> Waiting for HTTPS server to come up at https://$DOMAIN..."

MAX_RETRIES=120
RETRY_DELAY=2
COUNT=0

until curl -s --head "https://$DOMAIN" | grep -q "200 OK"; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
        echo "❌ Timed out waiting for https://$DOMAIN to become available."
        exit 1
    fi
    echo "  ⏳ Attempt $COUNT: server not up yet, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done

echo "✅ Domain is accessible via HTTPS: https://$DOMAIN"

echo "==> Verifying HTTP to HTTPS redirection..."
if curl -s -I "http://$DOMAIN" | grep -q "301 Moved Permanently"; then
    echo "✅ HTTP correctly redirects to HTTPS."
else
    echo "❌ HTTP to HTTPS redirect failed."
    exit 1
fi

echo "🎉 All checks passed! App is live and secured at: https://$DOMAIN"
