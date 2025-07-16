#!/bin/bash

jobid=${1}

# If we aren't provided with an id assume the last submit
if [[ "${jobid}" == "" ]];
   then
   jobid=$(flux job last)   
fi

echo "Jobid to start usernetes is ${jobid}"

# This is the nodelist - can be a single node or multiple
nodelist=$(flux jobs $(flux job last) --json | jq -r .nodelist)
nodelist=($(flux hostlist --expand $nodelist))
control_plane_node=${nodelist[0]}
worker_nodes=${nodelist[@]:1}

# This currently assumes one usernetes job running.
# We will want a way to have a custom logging file.
# We can likely remove this and have logs with service on node.
rm -rf /usr/workspace/usernetes/control-plane.log 

# Start the control plane
ssh $control_plane_node systemctl --user start usernetes-control-plane
echo "Log for control plane will be in /usr/workspace/usernetes/control-plane.log"

# The control plane is ready when this file exists
while true
  do
  ssh $control_plane_node "test -f /tmp/$USER/usernetes/source_env.sh"
  if [[ "$?" == "0" ]]; then
      echo "Usernetes control plane is ready."  
      ssh $control_plane_node systemctl --user status usernetes-control-plane
      break
  else
      sleep 3
  fi
done

# Start worker nodes
for worker_node in ${worker_nodes[@]}
  do
  ssh $worker_node systemctl --user start usernetes-worker
done

# Again wait for all workers to be ready

for worker_node in ${worker_nodes[@]}
  do
  ssh $worker_node "test -f /tmp/$USER/usernetes/source_env.sh"

  # If any single worker isn't ready, keep going
  if [[ "$?" != "0" ]]; then
      sleep 3
      continue
  fi

  # If we get here, all nodes are ready.
  break
done  

# Show the nodes. ssh does not honor cd to different directory
ssh $control_plane_node /bin/bash -c "cd /tmp/$USER/usernetes/ && . /tmp/$USER/usernetes/source_env.sh && kubectl get nodes"

# Install flannel and sync ips
ssh $control_plane_node /bin/bash -c "cd /tmp/$USER/usernetes/ && . /tmp/$USER/usernetes/source_env.sh && make -C /tmp/$USER/usernetes install-flannel"
ssh $control_plane_node /bin/bash -c "cd /tmp/$USER/usernetes/ && . /tmp/$USER/usernetes/source_env.sh && make -C /tmp/$USER/usernetes sync-external-ip"

# Shell in.
echo "Shelling into Usernetes control plane. Change directory to /tmp/$USER/usernetes and source_env.sh to use kubectl"
ssh $control_plane_node
