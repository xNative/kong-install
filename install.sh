#!/bin/bash
set -euo pipefail

wget https://github.com/xNative/kong-install/blob/main/kong-install.conf

wget https://github.com/xNative/kong-install/blob/main/kong-install.sh

printf 'cp\n' | bash kong-install.sh -v 3.4.2 -p kong