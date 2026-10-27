sudo ./kong-install.sh -m cp     # on the control plane
# copy /etc/kong/cluster.crt and cluster.key from the CP to each DP, then:
sudo ./kong-install.sh -m dp     # on each data plane
sudo ./kong-install.sh -m st     # standalone, if needed
