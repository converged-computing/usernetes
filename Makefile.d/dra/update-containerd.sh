#!/bin/bash
set -o errexit
set -o pipefail
set -o nounset
set -x
if grep -q "io.containerd.nri.v1.nri" /etc/containerd/config.toml
  then
    echo "containerd config contains NRI reference already; taking no action"
  else
    echo "containerd config does not mention NRI, thus enabling it";
    printf '%s\n' "[plugins.\"io.containerd.nri.v1.nri\"]" "  disable = false" "  disable_connections = false" "  plugin_config_path = \"/etc/nri/conf.d\"" "  plugin_path = \"/opt/nri/plugins\"" "  plugin_registration_timeout = \"5s\"" "  plugin_request_timeout = \"5s\"" "  socket_path = \"/var/run/nri/nri.sock\"" >> /etc/containerd/config.toml
    echo "restarting containerd"
    systemctl restart containerd
fi
