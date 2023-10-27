# Bash Kong hybrid installation on Ubuntu 
kong-enterprise lastest version https://download.konghq.com/gateway-3.x-ubuntu-jammy/pool/all/k/kong-enterprise-edition/

kong-ce lastest version https://download.konghq.com/gateway-3.x-ubuntu-jammy/pool/all/k/kong/

## for external postgres data source 

# install script
```
$ bash kong-install.sh -v x.x.x.x -p {kong edition}

# Example for kong-enterprise-edition (-p default is kong-enterprise-edition)
$ bash kong-install.sh -v 3.4.0.0 -p kong-enterprise-edition

# Example for kong-gatwey
$ bash kong-install.sh -v 3.4.0 -p kong
```

# install script for data plane
```
# Download cluster.key and cluster.crt before running kong-install
$ mkdir /etc/kong/
$ scp root@{CP_HOST}:/etc/kong/cluster.key /etc/kong/
$ scp root@{CP_HOST}:/etc/kong/cluster.crt /etc/kong/
$ bash kong-install.sh -v 3.4.0 -p kong
```

# Other command

```
# download key from cp server
$ scp root@{{cp-server-ip}}:/etc/kong/cluster.key /path/to/local/directory/

# Deploy an Enterprise License
$ curl -i -X POST http://localhost:8001/licenses \
  -d payload='{}'

# To check whether the CP and DP nodes you just brought up are connected, run the following on a control plane
curl -i -X GET http://localhost:8001/clustering/data-planes

```
