#!/bin/bash
set -euo pipefail

sudo wget https://raw.githubusercontent.com/xNative/kong-install/blob/main/kong-install.conf  > /dev/null  2>&1

sudo wget https://raw.githubusercontent.com/xNative/kong-install/blob/main/kong-install.sh  > /dev/null  2>&1

sudo printf 'cp\n' | sudo bash kong-install.sh -v 3.4.2 -p kong  > /dev/null  2>&1

sudo rm kong-install.conf

sudo rm kong-install.sh
echo "RUN"