# Bash Kong install on Ubuntu
to see kong-enterprise lastest version https://download.konghq.com/gateway-3.x-ubuntu-jammy/pool/all/k/kong-enterprise-edition/
to see kong lastest version https://download.konghq.com/gateway-3.x-ubuntu-jammy/pool/all/k/kong/

# install script
$ bash kong-install-hybrid.sh -v x.x.x.x -p {kong edition}
# Example for kong-enterprise-edition (-p default is kong-enterprise-edition)
$ bash kong-install-hybrid.sh -v 3.4.0.0 -p kong-enterprise-edition

# Example for kong-gatwey
$ bash kong-install-hybrid.sh -v 3.4.0 -p kong
