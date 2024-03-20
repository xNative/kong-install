#!/bin/bash
set -euo pipefail

sudo wget https://raw.githubusercontent.com/xNative/kong-install/main/kong-install.conf  > /dev/null  2>&1

sudo wget https://raw.githubusercontent.com/xNative/kong-install/main/kong-install.sh  > /dev/null  2>&1

sudo printf 'st\n' | sudo bash kong-install.sh -v 3.4.3.4 -p kong-enterprise  > /dev/null  2>&1

sudo rm kong-install.conf

sudo rm kong-install.sh
echo "RUN"
