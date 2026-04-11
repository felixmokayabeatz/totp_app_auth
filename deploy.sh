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
DOMAIN="153.75.224.243"

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
    else
        echo -e "${RED}✗ Not running${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Port $PORT:${NC}"
    check_port
}

# Function to create Django superuser
create_superuser() {
    echo -e "${YELLOW}Creating Django superuser...${NC}"
    
    # Activate virtual environment
    source $VENV_PATH/bin/activate
    
    # Navigate to backend directory
    cd $BACKEND_PATH
    
    # Check if superuser already exists
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
    
    # Create superuser using Django's createsuperuser command with environment variables
    echo -e "${BLUE}Creating superuser...${NC}"
    echo -e "Username: ${GREEN}$SUPERUSER_USERNAME${NC}"
    echo -e "Email: ${GREEN}$SUPERUSER_EMAIL${NC}"
    echo -e "First Name: ${GREEN}$SUPERUSER_FIRST_NAME${NC}"
    echo -e "Last Name: ${GREEN}$SUPERUSER_LAST_NAME${NC}"
    
    # Use Django's shell to create superuser (bypasses password prompts)
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
        echo -e "${YELLOW}You can now login at: http://$DOMAIN/admin/${NC}"
        echo -e "  Username: ${GREEN}$SUPERUSER_USERNAME${NC}"
        echo -e "  Password: ${GREEN}$SUPERUSER_PASSWORD${NC}"
    else
        echo -e "${RED}✗ Failed to create superuser${NC}"
    fi
}

# Function to copy config files from repo to system locations
copy_config_files() {
    echo -e "${YELLOW}Copying configuration files...${NC}"
    
    # Copy systemd service file
    if [ -f "$BACKEND_PATH/nginx/beatzlock.service" ]; then
        sudo cp "$BACKEND_PATH/nginx/beatzlock.service" /etc/systemd/system/
        echo -e "${GREEN}✓ Copied beatzlock.service${NC}"
    else
        echo -e "${RED}✗ beatzlock.service not found in $BACKEND_PATH/nginx/${NC}"
        return 1
    fi
    
    # Copy nginx config file
    if [ -f "$BACKEND_PATH/nginx/beatzlock.conf" ]; then
        sudo cp "$BACKEND_PATH/nginx/beatzlock.conf" /etc/nginx/sites-available/beatzlock
        echo -e "${GREEN}✓ Copied beatzlock.conf${NC}"
    else
        echo -e "${RED}✗ beatzlock.conf not found in $BACKEND_PATH/nginx/${NC}"
        return 1
    fi
    
    # Create symbolic link if not exists
    if [ ! -L "/etc/nginx/sites-enabled/beatzlock" ]; then
        sudo ln -sf /etc/nginx/sites-available/beatzlock /etc/nginx/sites-enabled/
        echo -e "${GREEN}✓ Created symbolic link${NC}"
    fi
    
    # Remove default nginx site
    if [ -L "/etc/nginx/sites-enabled/default" ]; then
        sudo rm -f /etc/nginx/sites-enabled/default
        echo -e "${GREEN}✓ Removed default nginx site${NC}"
    fi
    
    echo -e "${GREEN}✓ All config files copied successfully${NC}"
    return 0
}

# Function to full deploy
full_deploy() {
    echo -e "${GREEN}Starting full deployment...${NC}"
    
    # Update system
    echo -e "${YELLOW}[1/9] Updating system packages...${NC}"
    sudo apt update && sudo apt upgrade -y
    
    # Install dependencies
    echo -e "${YELLOW}[2/9] Installing dependencies...${NC}"
    sudo apt install -y python3 python3-pip python3-venv nginx git curl
    
    # Create directories
    echo -e "${YELLOW}[3/9] Creating directories...${NC}"
    mkdir -p $APP_PATH/logs $BACKEND_PATH/media $BACKEND_PATH/staticfiles
    
    # Pull latest code (since repo already cloned)
    echo -e "${YELLOW}[4/9] Pulling latest code from GitHub...${NC}"
    cd $APP_PATH && git pull
    
    # Setup virtual environment
    echo -e "${YELLOW}[5/9] Setting up Python environment...${NC}"
    if [ ! -d "$VENV_PATH" ]; then
        python3 -m venv $VENV_PATH
        echo -e "${GREEN}✓ Virtual environment created${NC}"
    else
        echo -e "${GREEN}✓ Virtual environment already exists${NC}"
    fi
    source $VENV_PATH/bin/activate
    pip install --upgrade pip
    pip install -r $BACKEND_PATH/requirements.txt gunicorn psycopg2-binary
    
    # Run migrations
    echo -e "${YELLOW}[6/9] Running migrations...${NC}"
    cd $BACKEND_PATH
    python manage.py migrate
    python manage.py collectstatic --noinput
    
    # Copy config files from repo to system
    echo -e "${YELLOW}[7/9] Installing configuration files...${NC}"
    copy_config_files
    
    # Update systemd service file with correct paths
    echo -e "${YELLOW}[8/9] Updating service file with correct paths...${NC}"
    sudo sed -i "s|/home/felixmokayabeatz/beatzlock|$APP_PATH|g" /etc/systemd/system/beatzlock.service
    sudo sed -i "s|/home/felixmokayabeatz/beatzlock/backend|$BACKEND_PATH|g" /etc/systemd/system/beatzlock.service
    
    # Restart services
    echo -e "${YELLOW}[9/9] Starting services...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable beatzlock
    sudo systemctl restart beatzlock
    sudo nginx -t && sudo systemctl restart nginx
    
    echo -e "${GREEN}✓ Full deployment complete!${NC}"
    check_services
    
    # Ask if user wants to create superuser
    echo ""
    echo -n "Do you want to create a Django superuser? (y/N): "
    read -r create_su
    if [[ "$create_su" =~ ^[Yy]$ ]]; then
        create_superuser
    fi
}

# Function for quick deploy
quick_deploy() {
    echo -e "${YELLOW}Quick deployment...${NC}"
    
    # Pull latest code
    echo -e "${BLUE}Pulling latest code...${NC}"
    cd $APP_PATH && git pull
    
    # Update dependencies
    echo -e "${BLUE}Updating dependencies...${NC}"
    source $VENV_PATH/bin/activate
    pip install -r $BACKEND_PATH/requirements.txt
    
    # Run migrations
    echo -e "${BLUE}Running migrations...${NC}"
    cd $BACKEND_PATH
    python manage.py migrate
    python manage.py collectstatic --noinput
    
    # Copy config files (in case they changed)
    echo -e "${BLUE}Updating configuration files...${NC}"
    copy_config_files
    
    # Restart service
    echo -e "${BLUE}Restarting services...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart beatzlock
    sudo nginx -t && sudo systemctl reload nginx
    
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
    fi
}

# Function to backup database
backup_db() {
    echo -e "${YELLOW}Backing up database...${NC}"
    BACKUP_FILE="$APP_PATH/backup_$(date +%Y%m%d_%H%M%S).sql"
    sqlite3 $BACKEND_PATH/db.sqlite3 ".backup $BACKUP_FILE"
    echo -e "${GREEN}✓ Database backed up to: $BACKUP_FILE${NC}"
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
        0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo ""
    echo -n "Press Enter to continue..."
    read
done