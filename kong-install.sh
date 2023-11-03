#!/bin/bash
set -euo pipefail
export TZ="Asia/Bangkok"
SYS_DATE=$(date +'%Y-%m-%d %H:%M')
echo "SYS_DATE: $SYS_DATE $TZ"

## Sourcing the Config File ##
. ./kong-install.conf

KONG_PACKAGE_NAME=kong-enterprise-edition
KONG_PACKAGE_VERSION=

function determine_os() {
  UNAME=$(uname | tr "[:upper:]" "[:lower:]")
  # If Linux, try to determine specific distribution
  if [ "$UNAME" == "linux" ]; then
      if [[ -f "/etc/os-release" ]]; then
          export DISTRO=$(awk -F= '/^NAME/{ gsub(/"/, "", $2); print $2}' /etc/os-release)
          export VERSION="$(awk -F= '/^VERSION_ID/{ gsub(/"/, "", $2); print $2}' /etc/os-release)"
      fi
  fi
  # For everything else (or if above failed), just use generic identifier
  [ "${DISTRO-x}" == "x" ] && export DISTRO=$UNAME
  unset UNAME
}

function ubuntu_install_package() {
    if [[ -n "$KONG_PACKAGE_VERSION" ]]; then
        KONG_PACKAGE="$KONG_PACKAGE_NAME=$KONG_PACKAGE_VERSION"
    else
        KONG_PACKAGE="$KONG_PACKAGE_NAME"
    fi

    echo
    echo "########################################################"
    echo "Installing $KONG_PACKAGE on Ubuntu"
    echo "########################################################"
    echo

    export DEBIAN_FRONTEND=noninteractive

    echo "Checking installed packages"

    # If sudo is not installed
    if [[ $(dpkg-query -W -f='${Status}' sudo 2>/dev/null | grep -c "ok installed") -eq 0 ]]; then
        apt-get update > /dev/null
        DEBCONF_NOWARNINGS=yes apt-get install -y sudo > /dev/null
    else
        sudo apt-get update > /dev/null
    fi

    # Ensure we have all the packages we need
    DEBCONF_NOWARNINGS=yes TZ=Etc/UTC sudo -E apt-get -y install tzdata lsb-release ca-certificates > /dev/null 2>&1


}
function ubuntu_install_kong() {
    # Configure Kong repo if needed
    if [[ ! -f /etc/apt/sources.list.d/kong.list ]]; then
        echo "Adding Kong repo"
        echo "deb [trusted=yes] https://download.konghq.com/gateway-3.x-ubuntu-$(lsb_release -sc)/ \
 default all" | sudo tee /etc/apt/sources.list.d/kong.list > /dev/null
        sudo apt-get update > /dev/null
    fi

    # If $KONG_PACKAGE is not installed
    if [[ $(dpkg-query -W -f='${Status}' $KONG_PACKAGE 2>/dev/null | grep -c "ok installed") -eq 0 ]]; then
        echo "Installing $KONG_PACKAGE"
        DEBCONF_NOWARNINGS=yes sudo -E apt-get install -y $KONG_PACKAGE > /dev/null
    else
        echo "$KONG_PACKAGE already installed"
    fi
}

function ubuntu_install_postgres() {
    # If postgresql is not installed
    if [[ $(dpkg-query -W -f='${Status}' postgresql 2>/dev/null | grep -c "ok installed") -eq 0 ]]; then
        echo "Installing postgresql"
        DEBCONF_NOWARNINGS=yes sudo -E apt-get install -y postgresql > /dev/null
    else
        echo "Postgres already installed"
    fi

    # Start Postgres
    sudo /etc/init.d/postgresql start > /dev/null
}

function run_kong_cp_install(){
    determine_os
    
    IS_ENTERPRISE=1
    if [[ $KONG_PACKAGE_NAME == "kong" ]]; then
        IS_ENTERPRISE=0
    fi

    if [[ $DISTRO == "Ubuntu" ]]; then
        ubuntu_install_package;
        ubuntu_install_kong;
    else
        echo "Unsupported OS: $DISTRO"
        exit 1
    fi

    # ==================================================
    # Platform independent config
    # ==================================================

    # Generate passwords
    KONG_PASSWORD=$(echo $RANDOM | md5sum | head -c 20)

    # Configure Postgres
    if [[ -n "$POSTGRES_PASSWORD" ]]; then
        echo "Configure External Postgres "
        DEBCONF_NOWARNINGS=yes sudo apt-get install postgresql-client -y > /dev/null
        PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -p $POSTGRES_PORT -d postgres -U postgres -c "CREATE USER kong WITH PASSWORD '$KONG_PASSWORD';" > /dev/null;
        PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -p $POSTGRES_PORT -d postgres -U postgres -c "GRANT kong TO postgres;" > /dev/null
        PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -p $POSTGRES_PORT -d postgres -U postgres -c "CREATE DATABASE kong OWNER kong;" > /dev/null
        PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -p $POSTGRES_PORT -d kong -U postgres -c "GRANT ALL ON SCHEMA public TO kong;" > /dev/null
    else
        ubuntu_install_postgres;
        if [[ $DB_EXISTS == 0 ]]; then
        sudo su - postgres -c "psql -c \"CREATE USER kong WITH PASSWORD '$KONG_PASSWORD';\" > /dev/null";
        sudo su - postgres -c "psql -c \"CREATE DATABASE kong OWNER kong\" > /dev/null";
        fi
    fi

    ## Configure Kong
    echo "Generating Certificage Key" 
    sudo env "PATH=$PATH" kong hybrid gen_cert > /dev/null 2>&1
    sudo cp ./cluster.crt /etc/kong/cluster.crt
    sudo cp ./cluster.key /etc/kong/cluster.key
    sudo rm ./cluster.key ./cluster.crt

    ## Configure Kong Non-Default
    echo "Configuring kong.conf"
    sudo cp -p /etc/kong/kong.conf.default /etc/kong/kong.conf
    sudo sed -i "$ a #============================================" $KONG_CONFIG
    sudo sed -i "$ a #===|          Kong Configured           |===" $KONG_CONFIG
    sudo sed -i "$ a # File: kong.conf" $KONG_CONFIG
    sudo sed -i "$ a # Configurator: $CONF_AUTHOR" $KONG_CONFIG
    sudo sed -i "$ a # Date: $SYS_DATE $TZ" $KONG_CONFIG
    sudo sed -i "$ a # Description: Non-Default Configuration" $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a # Change History:" $KONG_CONFIG
    sudo sed -i "$ a # YYYY-MM-DD: Description of the change and who made it." $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a # Version: 1.0" $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a ## Usage: $KONG_PACKAGE install in $yn mode" $KONG_CONFIG
    sudo sed -i "$ a #============================================" $KONG_CONFIG
    sudo sed -i "$ a pg_password = $KONG_PASSWORD" $KONG_CONFIG
    sudo sed -i "$ a role = control_plane" $KONG_CONFIG
    sudo sed -i "$ a cluster_cert = /etc/kong/cluster.crt" $KONG_CONFIG
    sudo sed -i "$ a cluster_cert_key = /etc/kong/cluster.key" $KONG_CONFIG
    sudo sed -i "$ a admin_listen = 0.0.0.0:8001 reuseport backlog=16384, 0.0.0.0:8444 http2 ssl reuseport backlog=16384" $KONG_CONFIG
    sudo sed -i "$ a #admin_gui_url = http://$HOST_CP:8002" $KONG_CONFIG

    if [[ -n "$POSTGRES_PASSWORD" ]]; then
     ## Configure Kong For Externall Postgres
    sudo sed -i "$ a pg_host = $POSTGRES_HOST" $KONG_CONFIG
    sudo sed -i "$ a pg_port = $POSTGRES_PORT" $KONG_CONFIG
    sudo sed -i "$ a pg_ssl = on" $KONG_CONFIG
    sudo sed -i "$ a pg_ssl_required = on" $KONG_CONFIG
    fi
    if [[ $IS_ENTERPRISE -gt 0 ]]; then
    ## Configure Kong For Enterprise Edition
    sudo sed -i "$ a portal = on" $KONG_CONFIG
    sudo sed -i "$ a portal_gui_host = $HOST_CP:8003" $KONG_CONFIG
    sudo sed -i "$ a enforce_rbac = on" $KONG_CONFIG
    sudo sed -i "$ a admin_gui_url = http://$HOST_CP:8002" $KONG_CONFIG
    sudo sed -i "$ a admin_gui_auth = basic-auth" $KONG_CONFIG
    sudo sed -i '$ a admin_gui_session_conf = {\"secret\":\"secret\",\"storage\":\"kong\",\"cookie_secure\":false}' $KONG_CONFIG
    sudo sed -i "$ a #====================| KONG_PASSWORD=$KONG_PASSWORD |====================" $KONG_CONFIG
    fi

    echo "Running Kong migrations"
    KONG_PASSWORD=$KONG_PASSWORD sudo -E env "PATH=$PATH" kong migrations bootstrap > /dev/null  2>&1


    echo "Starting Kong"
    sudo env "PATH=$PATH" kong start > /dev/null 2>&1

    # Output success
    echo
    echo "==================================================="
    echo "Kong Gateway is now running on your system"
    # echo "Ensure that port 8000 is open to the public"
    echo "Kong Manager is available on port 8002"
    if [[ $IS_ENTERPRISE -gt 0 ]]; then
    echo
    echo "See https://docs.konghq.com/gateway/latest/kong-manager/enable/ to enable the UI"
    echo "You can log in with the username 'kong_admin' and password '$KONG_PASSWORD'"
    fi
    echo "==================================================="
}

function run_kong_dp_install(){
    determine_os

    IS_ENTERPRISE=1
    if [[ $KONG_PACKAGE_NAME == "kong" ]]; then
        IS_ENTERPRISE=0
    fi

    if [[ $DISTRO == "Ubuntu" ]]; then
        ubuntu_install_package;
        ubuntu_install_kong;
    else
        echo "Unsupported OS: $DISTRO"
        exit 1
    fi

    # ==================================================
    # Platform independent config
    # ==================================================
    
    # Configure Kong
    echo "Running Configuring Kong"
    # CONFIG HEADER SECTION
    sudo sed -i "$ a #============================================" $KONG_CONFIG
    sudo sed -i "$ a #===|          Kong Configured           |===" $KONG_CONFIG
    sudo sed -i "$ a # File: kong.conf" $KONG_CONFIG
    sudo sed -i "$ a # Configurator: $CONF_AUTHOR" $KONG_CONFIG
    sudo sed -i "$ a # Date: $SYS_DATE $TZ" $KONG_CONFIG
    sudo sed -i "$ a # Description: Non-Default Configuration" $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a # Change History:" $KONG_CONFIG
    sudo sed -i "$ a # YYYY-MM-DD: Description of the change and who made it." $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a # Version: 1.0" $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a ## Usage: $KONG_PACKAGE install in $yn mode" $KONG_CONFIG
    sudo sed -i "$ a #============================================" $KONG_CONFIG
    # CONFIG HEADER SECTION END
    sudo sed -i "$ a role = data_plane" $KONG_CONFIG
    sudo sed -i "$ a database = off " $KONG_CONFIG
    sudo sed -i "$ a proxy_listen = 0.0.0.0:80 reuseport backlog=16384, 0.0.0.0:443 http2 ssl reuseport backlog=16384" $KONG_CONFIG
    sudo sed -i "$ a cluster_cert = /etc/kong/cluster.crt " $KONG_CONFIG
    sudo sed -i "$ a cluster_cert_key = /etc/kong/cluster.key " $KONG_CONFIG
    sudo sed -i "$ a cluster_control_plane = $HOST_CP:8005 " $KONG_CONFIG

    if [[ $IS_ENTERPRISE -gt 0 ]]; then
    #cluster_telemetry_endpoint for enterpise version
    sudo sed -i "$ a cluster_telemetry_endpoint = $HOST_CP:8006 " $KONG_CONFIG
    fi

    echo "Starting Kong"
    sudo env "PATH=$PATH" kong start > /dev/null 2>&1

    # Output success
    echo
    echo "==================================================="
    echo "Kong Data Plane is now configure on your system"
    echo "==================================================="
}

function run_kong_st_install(){
    determine_os

    IS_ENTERPRISE=1
    if [[ $KONG_PACKAGE_NAME == "kong" ]]; then
        IS_ENTERPRISE=0
    fi

    if [[ $DISTRO == "Ubuntu" ]]; then
        ubuntu_install_package;
        ubuntu_install_kong;
        ubuntu_install_postgres;
    else
        echo "Unsupported OS: $DISTRO"
        exit 1
    fi

    # ==================================================
    # Platform independent config
    # ==================================================

    # Generate passwords
    KONG_PASSWORD=$(echo $RANDOM | md5sum | head -c 20)

    # Configure Postgres
    DB_EXISTS=$(sudo su - postgres -c "psql -lqt" | cut -d \| -f 1 | grep -w kong | wc -l) || true
    if [[ $DB_EXISTS == 0 ]]; then
        sudo su - postgres -c "psql -c \"CREATE USER kong WITH PASSWORD '$KONG_PASSWORD';\" > /dev/null";
        sudo su - postgres -c "psql -c \"CREATE DATABASE kong OWNER kong\" > /dev/null";
    fi

    # Configure Kong
    echo "Running Kong migrations"
    sudo cp /etc/kong/kong.conf.default /etc/kong/kong.conf
        # CONFIG HEADER SECTION
    sudo sed -i "$ a #============================================" $KONG_CONFIG
    sudo sed -i "$ a #===|          Kong Configured           |===" $KONG_CONFIG
    sudo sed -i "$ a # File: kong.conf" $KONG_CONFIG
    sudo sed -i "$ a # Configurator: $CONF_AUTHOR" $KONG_CONFIG
    sudo sed -i "$ a # Date: $SYS_DATE $TZ" $KONG_CONFIG
    sudo sed -i "$ a # Description: Non-Default Configuration" $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a # Change History:" $KONG_CONFIG
    sudo sed -i "$ a # YYYY-MM-DD: Description of the change and who made it." $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a # Version: 1.0" $KONG_CONFIG
    sudo sed -i "$ a # " $KONG_CONFIG
    sudo sed -i "$ a ## Usage: $KONG_PACKAGE install in $yn mode" $KONG_CONFIG
    sudo sed -i "$ a #============================================" $KONG_CONFIG
        # CONFIG HEADER SECTION END
    sudo sed -i "$ a pg_password = $KONG_PASSWORD" $KONG_CONFIG
    sudo sed -i "$ a proxy_listen = 0.0.0.0:80 reuseport backlog=16384, 0.0.0.0:443 http2 ssl reuseport backlog=16384" $KONG_CONFIG

    KONG_PASSWORD=$KONG_PASSWORD sudo -E env "PATH=$PATH" kong migrations bootstrap > /dev/null  2>&1

    echo "Starting Kong"
    sudo env "PATH=$PATH" kong start > /dev/null 2>&1

    # Output success
    echo
    echo "==================================================="
    echo "Kong Gateway is now running on your system"
    echo "Ensure that port 8000 is open to the public"
    if [[ $IS_ENTERPRISE -gt 0 ]]; then
    echo
    echo "See https://docs.konghq.com/gateway/latest/kong-manager/enable/ to enable the UI"
    echo "You can log in with the username 'kong_admin' and password '$KONG_PASSWORD'"
    fi
    echo "==================================================="
} 


## GET PARAM -p {package} -v {version}
  while getopts "p:v:" o; do
    case "${o}" in
        p)
            KONG_PACKAGE_NAME=${OPTARG}
            ;;
        v)
            KONG_PACKAGE_VERSION=${OPTARG}
            ;;
    esac
done

echo "This script will install Kong Gateway in Hybride mode, where it acts as both the Control Plane or Data Plane. Running in this mode is suitable for production/UAT."
echo "Choose the function you want to depoloy. [cp] Controlplane, [dp] Dataplane, [st] Standalone"
echo
while true; do
    read -p "Install Kong Enterprise Hybrid Mode? (cp/dp/st)" yn
    case $yn in
        [cp]* ) run_kong_cp_install; break;;
        [dp]* ) run_kong_dp_install; break;;
        [st]* ) run_kong_st_install; break;;
        * ) echo "Please answer cp or dp.";;
    esac
done