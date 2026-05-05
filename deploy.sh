#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
APP_NAME="beatzlock"
APP_USER="felixmokayabeatz"
APP_PATH="/home/$APP_USER/totp_app"
BACKEND_PATH="$APP_PATH/otp_backend"
VENV_PATH="$APP_PATH/totp_app_venv"
PORT="8002"
DOMAIN="api.felixmokayabeatz.online"
EMAIL="felixmokaya675@gmail.com"

# Superuser credentials
SUPERUSER_USERNAME="felixmokayabeatz"
SUPERUSER_EMAIL="felixmokaya675@gmail.com"
SUPERUSER_PASSWORD="Ableton@2429"
SUPERUSER_FIRST_NAME="Felix"
SUPERUSER_LAST_NAME="Mokaya"

# Function to show menu
show_menu() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    BeatzLock Authenticator Manager${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}1.${NC} Full Deploy (First time or full update)"
    echo -e "${GREEN}2.${NC} Quick Deploy (Pull & restart only)"
    echo -e "${GREEN}3.${NC} Check Services Status"
    echo -e "${GREEN}4.${NC} Restart Services"
    echo -e "${GREEN}5.${NC} View Logs"
    echo -e "${GREEN}6.${NC} Stop Services"
    echo -e "${GREEN}7.${NC} Start Services"
    echo -e "${GREEN}8.${NC} Reload Nginx Only"
    echo -e "${GREEN}9.${NC} Backup Database"
    echo -e "${GREEN}10.${NC} Show Port Status"
    echo -e "${GREEN}11.${NC} Create Django Superuser"
    echo -e "${GREEN}12.${NC} Install/Renew SSL Certificate"
    echo -e "${RED}0.${NC} Exit"
    echo -e "${BLUE}========================================${NC}"
    echo -n "Choose option: "
}

# Function to check if port is in use
check_port() {
    if sudo netstat -tlnp | grep -q ":$PORT "; then
        echo -e "${YELLOW}⚠ Port $PORT is in use${NC}"
        sudo netstat -tlnp | grep ":$PORT "
        return 0
    else
        echo -e "${GREEN}✓ Port $PORT is free${NC}"
        return 1
    fi
}

# Function to install SSL certificate
install_ssl() {
    echo -e "${YELLOW}Installing/Updating SSL certificate for $DOMAIN...${NC}"
    
    # Install certbot if not installed
    if ! command -v certbot &> /dev/null; then
        echo -e "${BLUE}Installing Certbot...${NC}"
        sudo apt update
        sudo apt install -y certbot python3-certbot-nginx
    fi
    
    # Ensure nginx is running
    sudo systemctl start nginx
    
    # Test nginx config first
    if ! sudo nginx -t 2>/dev/null; then
        echo -e "${RED}✗ Nginx config has errors. Please fix before installing SSL.${NC}"
        return 1
    fi
    
    # Get SSL certificate
    echo -e "${BLUE}Obtaining SSL certificate...${NC}"
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ SSL certificate installed successfully!${NC}"
        
        # Setup auto-renewal (only for this domain)
        echo -e "${BLUE}Setting up auto-renewal...${NC}"
        (sudo crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 0,12 * * * certbot renew --quiet --nginx --cert-name $DOMAIN") | sudo crontab -
        echo -e "${GREEN}✓ Auto-renewal configured${NC}"
        
        # Test renewal for this domain only
        echo -e "${BLUE}Testing certificate renewal...${NC}"
        sudo certbot renew --dry-run --cert-name $DOMAIN
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Auto-renewal test passed${NC}"
        else
            echo -e "${YELLOW}⚠ Auto-renewal test had issues, but certificate is still valid${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to install SSL certificate${NC}"
        echo -e "${YELLOW}Make sure your domain DNS is correctly pointing to this server${NC}"
        echo -e "${YELLOW}And ensure nginx config is ready (HTTP on port 80)${NC}"
        return 1
    fi
}

# Function to check service status
check_services() {
    echo -e "${YELLOW}Checking services...${NC}"
    echo ""
    
    echo -e "${BLUE}Gunicorn (Django):${NC}"
    if sudo systemctl is-active --quiet beatzlock; then
        echo -e "${GREEN}✓ Running${NC}"
        sudo systemctl status beatzlock --no-pager | grep -E "Active:|Main PID:|CGroup:"
    else
        echo -e "${RED}✗ Not running${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Nginx:${NC}"
    if sudo systemctl is-active --quiet nginx; then
        echo -e "${GREEN}✓ Running${NC}"
        sudo nginx -t 2>&1 | head -1
    else
        echo -e "${RED}✗ Not running${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}SSL Certificate ($DOMAIN):${NC}"
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo -e "${GREEN}✓ Installed${NC}"
        EXPIRY=$(sudo certbot certificates 2>/dev/null | grep -A 5 "$DOMAIN" | grep "Expiry Date" | head -1 | sed 's/.*Expiry Date: //')
        if [ ! -z "$EXPIRY" ]; then
            echo -e "  Expires: $EXPIRY"
        fi
    else
        echo -e "${YELLOW}⚠ Not installed${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Port $PORT:${NC}"
    check_port
    
    echo ""
    echo -e "${BLUE}API Endpoint Test:${NC}"
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/api/ | grep -q "200\|301\|302"; then
        echo -e "${GREEN}✓ API responding on port $PORT${NC}"
    else
        echo -e "${RED}✗ API not responding${NC}"
    fi
}

# Function to create Django superuser
create_superuser() {
    echo -e "${YELLOW}Creating Django superuser...${NC}"
    
    source $VENV_PATH/bin/activate
    cd $BACKEND_PATH
    
    echo -e "${BLUE}Checking if superuser exists...${NC}"
    USER_EXISTS=$(python manage.py shell -c "from django.contrib.auth.models import User; print(User.objects.filter(username='$SUPERUSER_USERNAME').exists())" 2>/dev/null)
    
    if [ "$USER_EXISTS" = "True" ]; then
        echo -e "${YELLOW}⚠ Superuser '$SUPERUSER_USERNAME' already exists.${NC}"
        echo -n "Do you want to delete and recreate? (y/N): "
        read -r recreate
        if [[ "$recreate" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Deleting existing superuser...${NC}"
            python manage.py shell -c "from django.contrib.auth.models import User; User.objects.filter(username='$SUPERUSER_USERNAME').delete()"
            echo -e "${GREEN}✓ Existing superuser deleted${NC}"
        else
            echo -e "${GREEN}✓ Keeping existing superuser${NC}"
            return 0
        fi
    fi
    
    echo -e "${BLUE}Creating superuser...${NC}"
    python manage.py shell << EOF
from django.contrib.auth.models import User
if not User.objects.filter(username='$SUPERUSER_USERNAME').exists():
    user = User.objects.create_superuser(
        username='$SUPERUSER_USERNAME',
        email='$SUPERUSER_EMAIL',
        password='$SUPERUSER_PASSWORD'
    )
    user.first_name = '$SUPERUSER_FIRST_NAME'
    user.last_name = '$SUPERUSER_LAST_NAME'
    user.save()
    print('Superuser created successfully!')
else:
    print('Superuser already exists')
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Superuser created successfully!${NC}"
        echo -e "${YELLOW}Login at: https://$DOMAIN/admin/${NC}"
        echo -e "  Username: ${GREEN}$SUPERUSER_USERNAME${NC}"
        echo -e "  Password: ${GREEN}$SUPERUSER_PASSWORD${NC}"
    else
        echo -e "${RED}✗ Failed to create superuser${NC}"
    fi
}

# Function to copy systemd service file only (NO NGINX)
copy_service_file() {
    echo -e "${YELLOW}Installing systemd service file...${NC}"
    
    # Create systemd service file directly
    sudo tee /etc/systemd/system/beatzlock.service > /dev/null << 'EOF'
[Unit]
Description=BeatzLock Authenticator Django Application
After=network.target

[Service]
User=felixmokayabeatz
Group=felixmokayabeatz
WorkingDirectory=/home/felixmokayabeatz/totp_app/otp_backend
Environment="PATH=/home/felixmokayabeatz/totp_app/totp_app_venv/bin"
Environment="DJANGO_SETTINGS_MODULE=otp_backend.settings"
Environment="DJANGO_ALLOWED_HOSTS=api.felixmokayabeatz.online,localhost,127.0.0.1"
ExecStart=/home/felixmokayabeatz/totp_app/totp_app_venv/bin/gunicorn otp_backend.wsgi:application --bind 127.0.0.1:8002 --workers 3 --timeout 120 --access-logfile /home/felixmokayabeatz/totp_app/logs/gunicorn_access.log --error-logfile /home/felixmokayabeatz/totp_app/logs/gunicorn_error.log
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Service file installed${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to install service file${NC}"
        return 1
    fi
}

# Function to full deploy
full_deploy() {
    echo -e "${GREEN}Starting full deployment...${NC}"
    
    echo -e "${YELLOW}[1/9] Updating system packages...${NC}"
    sudo apt update && sudo apt upgrade -y
    
    echo -e "${YELLOW}[2/9] Installing dependencies...${NC}"
    sudo apt install -y python3 python3-pip python3-venv nginx git curl net-tools
    
    echo -e "${YELLOW}[3/9] Creating directories...${NC}"
    mkdir -p $APP_PATH/logs $BACKEND_PATH/media $BACKEND_PATH/staticfiles
    
    echo -e "${YELLOW}[4/9] Pulling latest code...${NC}"
    cd $APP_PATH && git pull
    
    echo -e "${YELLOW}[5/9] Setting up Python environment...${NC}"
    if [ ! -d "$VENV_PATH" ]; then
        python3 -m venv $VENV_PATH
        echo -e "${GREEN}✓ Virtual environment created${NC}"
    fi
    source $VENV_PATH/bin/activate
    python3 -m ensurepip --upgrade
    pip install --upgrade pip
    pip install -r $BACKEND_PATH/requirements.txt gunicorn psycopg2-binary
    
    echo -e "${YELLOW}[6/9] Running migrations...${NC}"
    cd $BACKEND_PATH
    python manage.py migrate
    python manage.py collectstatic --noinput
    
    echo -e "${YELLOW}[7/9] Installing service file...${NC}"
    copy_service_file
    
    echo -e "${YELLOW}[8/9] Starting services...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable beatzlock
    sudo systemctl restart beatzlock
    
    # Test and reload nginx (without modifying config)
    if sudo nginx -t 2>/dev/null; then
        sudo systemctl restart nginx
        echo -e "${GREEN}✓ Nginx config OK, restarted${NC}"
    else
        echo -e "${YELLOW}⚠ Nginx config has issues, please check manually${NC}"
    fi
    
    echo -e "${YELLOW}[9/9] Final checks...${NC}"
    sleep 3
    check_services
    
    echo -e "${GREEN}✓ Full deployment complete!${NC}"
    
    # Ask about SSL
    echo ""
    echo -n "Do you want to install SSL certificate? (y/N): "
    read -r install_ssl_now
    if [[ "$install_ssl_now" =~ ^[Yy]$ ]]; then
        install_ssl
    fi
    
    # Ask about superuser
    echo -n "Do you want to create a Django superuser? (y/N): "
    read -r create_su
    if [[ "$create_su" =~ ^[Yy]$ ]]; then
        create_superuser
    fi
}

# Function for quick deploy
quick_deploy() {
    echo -e "${YELLOW}Quick deployment...${NC}"
    
    echo -e "${BLUE}Pulling latest code...${NC}"
    cd $APP_PATH && git pull
    
    echo -e "${BLUE}Updating dependencies...${NC}"
    source $VENV_PATH/bin/activate
    pip install -r $BACKEND_PATH/requirements.txt
    
    echo -e "${BLUE}Running migrations...${NC}"
    cd $BACKEND_PATH
    python manage.py migrate
    python manage.py collectstatic --noinput
    
    echo -e "${BLUE}Restarting services...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart beatzlock
    
    if sudo nginx -t 2>/dev/null; then
        sudo systemctl reload nginx
        echo -e "${GREEN}✓ Nginx reloaded${NC}"
    fi
    
    echo -e "${GREEN}✓ Quick deploy complete!${NC}"
    check_services
}

# Function to restart services
restart_services() {
    echo -e "${YELLOW}Restarting services...${NC}"
    sudo systemctl restart beatzlock
    sudo systemctl restart nginx
    echo -e "${GREEN}✓ Services restarted${NC}"
    sleep 2
    check_services
}

# Function to stop services
stop_services() {
    echo -e "${YELLOW}Stopping services...${NC}"
    sudo systemctl stop beatzlock
    sudo systemctl stop nginx
    echo -e "${GREEN}✓ Services stopped${NC}"
}

# Function to start services
start_services() {
    echo -e "${YELLOW}Starting services...${NC}"
    sudo systemctl start beatzlock
    sudo systemctl start nginx
    echo -e "${GREEN}✓ Services started${NC}"
    sleep 2
    check_services
}

# Function to view logs
view_logs() {
    echo -e "${BLUE}Recent logs:${NC}"
    sudo journalctl -u beatzlock -n 50 --no-pager
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to exit live logs${NC}"
    sleep 2
    sudo journalctl -u beatzlock -f
}

# Function to reload nginx only
reload_nginx() {
    echo -e "${YELLOW}Reloading Nginx...${NC}"
    sudo nginx -t
    if [ $? -eq 0 ]; then
        sudo systemctl reload nginx
        echo -e "${GREEN}✓ Nginx reloaded successfully${NC}"
    else
        echo -e "${RED}✗ Nginx config has errors${NC}"
        echo -e "${YELLOW}Run: sudo nginx -t to see details${NC}"
    fi
}

# Function to backup database
backup_db() {
    echo -e "${YELLOW}Backing up database...${NC}"
    BACKUP_FILE="$APP_PATH/backup_$(date +%Y%m%d_%H%M%S).sql"
    if [ -f "$BACKEND_PATH/db.sqlite3" ]; then
        sqlite3 $BACKEND_PATH/db.sqlite3 ".backup $BACKUP_FILE"
        echo -e "${GREEN}✓ Database backed up to: $BACKUP_FILE${NC}"
    else
        echo -e "${RED}✗ Database file not found${NC}"
    fi
}

# Main loop
while true; do
    show_menu
    read choice
    
    case $choice in
        1) full_deploy ;;
        2) quick_deploy ;;
        3) check_services ;;
        4) restart_services ;;
        5) view_logs ;;
        6) stop_services ;;
        7) start_services ;;
        8) reload_nginx ;;
        9) backup_db ;;
        10) check_port ;;
        11) create_superuser ;;
        12) install_ssl ;;
        0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo ""
    echo -n "Press Enter to continue..."
    read
done