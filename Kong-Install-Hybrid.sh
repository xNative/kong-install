#!/bin/bash
set -euo pipefail

#    Kong Installation Hybrid Mode   #

KONG_PACKAGE_NAME=kong-enterprise-edition
KONG_PACKAGE_VERSION=
KONG_CONFIG="/etc/kong/kong.conf"

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

function os_install_ubuntu() {
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

function run_kong_cp_install(){
    determine_os

    if [[ $DISTRO == "Ubuntu" ]]; then
        os_install_ubuntu
    else
        echo "Unsupported OS: $DISTRO"
        exit 1
    fi

    # ==================================================
    # Platform independent config
    # ==================================================
    
    # Configure Postgres
    echo "Configure Postgres"
    DEBCONF_NOWARNINGS=yes sudo apt-get install postgresql-client -y > /dev/null
    PGPASSWORD='Cloudhm2023' psql -h database-kong-cp.c73x71zheyse.ap-southeast-1.rds.amazonaws.com -p 5432 -d postgres -U postgres -c "CREATE USER kong WITH PASSWORD 'Cloudhm2023';" > /dev/null;
    PGPASSWORD='Cloudhm2023' psql -h database-kong-cp.c73x71zheyse.ap-southeast-1.rds.amazonaws.com -p 5432 -d postgres -U postgres -c "GRANT kong TO postgres; CREATE DATABASE kong OWNER kong;" > /dev/null;

    # Configure Kong
    echo "Generating CertKey" 
    sudo env "PATH=$PATH" kong hybrid gen_cert > /dev/null 2>&1
    sudo cp ./cluster.crt /etc/kong/cluster.crt
    sudo cp ./cluster.key /etc/kong/cluster.key

    # Configure Kong
    echo "Running Kong migrations"
    sudo cp -p /etc/kong/kong.conf.default /etc/kong/kong.conf
    sudo sed -i 's/#pg_password =/pg_password = Cloudhm2023/' /etc/kong/kong.conf
    sudo sed -i "$ a portal = on" $KONG_CONFIG
    sudo sed -i "$ a pg_host = database-kong-cp.c73x71zheyse.ap-southeast-1.rds.amazonaws.com" $KONG_CONFIG
    sudo sed -i "$ a role = control_plane" $KONG_CONFIG
    sudo sed -i "$ a cluster_cert = /etc/kong/cluster.crt" $KONG_CONFIG
    sudo sed -i "$ a cluster_cert_key = /etc/kong/cluster.key" $KONG_CONFIG
    # echo "portal_gui_host = 10.5.65.57:8003" >> $KONG_CONFIG
    # # admin_gui_url : for Kong manager url needed to set here
    # echo "admin_gui_url = http://10.5.65.57:8002" >> $KONG_CONFIG
    # echo "admin_listen = 0.0.0.0:8001, 0.0.0.0:8003, 0.0.0.0:8444 ssl, 127.0.0.1:8001, 127.0.0.1:8003, 127.0.0.1:8444 ssl" >> $KONG_CONFIG
    KONG_PASSWORD=password sudo -E env "PATH=$PATH" kong migrations bootstrap > /dev/null  2>&1

    echo "Starting Kong"
    sudo env "PATH=$PATH" kong start > /dev/null 2>&1

    # Output success
    echo
    echo "==================================================="
    echo "Kong Control Plane is now running on your system"
    echo "==================================================="
} 

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

function run_kong_dp_install(){
    determine_os

    if [[ $DISTRO == "Ubuntu" ]]; then
        os_install_ubuntu
    else
        echo "Unsupported OS: $DISTRO"
        exit 1
    fi

    # ==================================================
    # Platform independent config
    # ==================================================
    
    # Configure Kong
    echo "Running Configuring Kong"
    sudo sed -i "$ a role = data_plane" $KONG_CONFIG
    sudo sed -i "$ a database = off " $KONG_CONFIG
    sudo sed -i "$ a proxy_listen = 0.0.0.0:80 reuseport backlog=16384, 0.0.0.0:443 http2 ssl reuseport backlog=16384" $KONG_CONFIG
    # NOTE <admin-hostname>:<port> NOT control-plane.<admin-hostname>.com:<port> 
    sudo sed -i "$ a cluster_control_plane = x.x.x.x:8005 " $KONG_CONFIG
    sudo sed -i "$ a cluster_telemetry_endpoint = x.x.x.x:8006 " $KONG_CONFIG
    sudo sed -i "$ a cluster_cert = /etc/kong/cluster.crt " $KONG_CONFIG
    sudo sed -i "$ a cluster_cert_key = /etc/kong/cluster.key " $KONG_CONFIG
    

    # echo "Starting Kong"
    sudo env "PATH=$PATH" kong start > /dev/null 2>&1

    # Output success
    echo
    echo "==================================================="
    echo "Kong Data Plane is now running on your system"
    echo "==================================================="
} 

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
echo
while true; do
    read -p "Install Kong Enterprise Hybrid Mode? (cp/dp)" yn
    case $yn in
        [cp]* ) run_kong_cp_install; break;;
        [dp]* ) run_kong_dp_install; break;;
        * ) echo "Please answer cp or dp.";;
    esac
done