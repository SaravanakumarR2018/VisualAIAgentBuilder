#!/bin/bash

set -e

DOCKER_IMAGE=""
DOMAIN=""

usage() {
    echo "Usage: $0 [--image <docker_image_tag>] [--domain <domain>]"
    echo "Example:"
    echo "  $0 --image saravanakr/langflow:1.4.2 --domain demo-aiagentsbuilder.duckdns.org"
    echo "  $0 --domain example.com"
    echo "  $0 --image myimage:latest"
    exit 1
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case $1 in
        --image)
            shift
            if [[ $# -eq 0 ]]; then
                echo "Error: --image requires a value"
                usage
            fi
            DOCKER_IMAGE="$1"
            shift
            ;;
        --domain)
            shift
            if [[ $# -eq 0 ]]; then
                echo "Error: --domain requires a value"
                usage
            fi
            DOMAIN="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$DOCKER_IMAGE" ] && [ -z "$DOMAIN" ]; then
    echo "Error: At least one of --image or --domain must be specified."
    usage
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

if [ -n "$DOCKER_IMAGE" ]; then
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
fi

if [ -n "$DOMAIN" ]; then
    echo "==> Setting up NGINX reverse proxy for $DOMAIN..."
    cat > /etc/nginx/sites-available/langflow <<EOF
server {
    listen 80 default_server;
    server_name www.$DOMAIN;
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name www.$DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

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

    # Remove default site if it exists to prevent conflicts
    if [ -e /etc/nginx/sites-enabled/default ]; then
        echo "==> Removing default NGINX site to avoid conflicts..."
        rm -f /etc/nginx/sites-enabled/default
    fi

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
    certbot --nginx --non-interactive --agree-tos --redirect --expand -d "$DOMAIN" -d "www.$DOMAIN" -m admin@$DOMAIN

    # --- Fix www redirection after Certbot modifies NGINX config ---
    echo "==> Re-applying NGINX config to ensure www.$DOMAIN redirects to $DOMAIN..."
    cat > /etc/nginx/sites-available/langflow <<EOF
server {
    listen 80 default_server;
    server_name www.$DOMAIN;
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name www.$DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

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
    systemctl reload nginx
    # --- End fix ---

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

    # Additional verification for www domain redirection
    echo "==> Verifying http://www.$DOMAIN redirects to https://$DOMAIN..."
    echo "DEBUG: Running curl for http://www.$DOMAIN"
    WWW_HTTP_HEADERS=$(curl -s -I "http://www.$DOMAIN")
    echo "DEBUG: Headers received for http://www.$DOMAIN:"
    echo "$WWW_HTTP_HEADERS"
    WWW_HTTP_STATUS=$(echo "$WWW_HTTP_HEADERS" | grep -i "^HTTP/" | head -1 | awk '{print $2}')
    WWW_HTTP_LOCATION=$(echo "$WWW_HTTP_HEADERS" | grep -iE "^location: https://$DOMAIN")
    if [ "$WWW_HTTP_STATUS" = "301" ] && [ -n "$WWW_HTTP_LOCATION" ]; then
        echo "✅ http://www.$DOMAIN redirects to https://$DOMAIN."
    else
        echo "❌ http://www.$DOMAIN does not redirect to https://$DOMAIN."
        exit 1
    fi
    echo "DEBUG: Completed check for http://www.$DOMAIN"

    echo "==> Verifying https://www.$DOMAIN redirects to https://$DOMAIN..."
    echo "DEBUG: Running curl for https://www.$DOMAIN"
    WWW_HTTPS_HEADERS=$(curl -s -I "https://www.$DOMAIN" --insecure)
    echo "DEBUG: Headers received for https://www.$DOMAIN:"
    echo "$WWW_HTTPS_HEADERS"
    WWW_HTTPS_REDIRECT=$(echo "$WWW_HTTPS_HEADERS" | grep -iE "^location: https://$DOMAIN")
    if [ -n "$WWW_HTTPS_REDIRECT" ]; then
        echo "✅ https://www.$DOMAIN redirects to https://$DOMAIN."
    else
        echo "❌ https://www.$DOMAIN does not redirect to https://$DOMAIN."
        exit 1
    fi
    echo "DEBUG: Completed check for https://www.$DOMAIN"

    echo "==> Final check: https://$DOMAIN is accessible..."
    if curl -s --head "https://$DOMAIN" | grep -q "200 OK"; then
        echo "✅ https://$DOMAIN is accessible."
    else
        echo "❌ https://$DOMAIN is not accessible."
        exit 1
    fi

    echo "🎉 All checks passed! App is live and secured at: https://$DOMAIN"
fi
