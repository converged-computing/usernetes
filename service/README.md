# Usernetes as a User Service

We were having trouble with interactive and ssh execution, so I am testing writing a systemctl user service.
For this to work, add each of the .service files to `~/.config/systemd/user` and then do the following.

## Usage

### Allocation

Request a flux alloc for the control plane and a worker, for however many minutes or hours you need.

```bash
flux alloc --bg -N2 -q pbatch -t 8h
```

### Control Plane

TODO: `export QUICK=1`

```bash
ssh corona189
# For the control plane - start
rm -rf /usr/workspace/usernetes/control-plane.log 
systemctl --user start usernetes-control-plane
systemctl --user status usernetes-control-plane
# check log in /usr/workspace/usernetes/control-plane.log
```

Importantly, in the above you need a podman-compose that has the line to add a label for `PODMAN_SYSTEMD_UNIT` commented out. If when you are in the usernetes kubelet container (`make shell`) or a container and `ulimit -l` is not unlimited, Infiniband is unlikely to work.

### Worker

```bash
ssh corona190
rm -rf /usr/workspace/usernetes/worker.log 
systemctl --user start usernetes-worker-calico
systemctl --user status usernetes-worker-calico
# check log in /usr/workspace/usernetes/worker.log
```

Back on the control plane (if everything looks good) we can go to the copied control plane directory, source a file to get kubectl and the correct paths, and see our cluster.

```bash
. source_env.sh
make sync-external-ip
make install-calico
```

Install the Flux Operator...

```bash
kubectl apply -f https://raw.githubusercontent.com/flux-framework/flux-operator/refs/heads/main/examples/dist/flux-operator.yaml
```

Test away! Good luck. Other containers to try:


```bash
# testing bare metal - 53 seconds
flux run -N1 -n 48 /usr/workspace/usernetes/lammps/build/install/bin/lmp -v x 8 -v y 8 -v z 8 -in in.reaxc.hns -nocite

# 2 nodes, 29 seconds
flux run -N2 -n 96 /usr/workspace/usernetes/lammps/build/install/bin/lmp -v x 8 -v y 8 -v z 8 -in in.reaxc.hns -nocite

# mpirun with one node: 1:18s
/opt/toss/openmpi/4.1/gnu/bin/mpirun --allow-run-as-root --mca plm_rsh_agent "" -np 48 lmp -v x 8 -v y 8 -v z 8 -in in.reaxc.hns -nocite

# OSU Latency (need to compare these two)
flux run -N2 -n2 osu_latency
flux run -N2 --env UCX_TLS=rc_x,sm,self --env OMPI_MCA_pml=ucx --env UCX_NET_DEVICES=mlx5_0:1 -n2 osu_latency

# LAMMPS (many of these likely aren't required, we will learn with experiments)
export OMPI_MCA_opal_warn_on_missing_libcuda=0
export OMPI_MCA_btl=^openib,self,vader
export OMPI_MCA_pml=ucx
export OMPI_MCA_osc=ucx
export UCX_TLS=all
flux run -N2 -opmi=pmi2 -n 96 lmp -v x 8 -v y 8 -v z 8 -in in.reaxc.hns -nocite

export OMPI_MCA_pml=ucx
export UCX_MEMTYPE_CACHE=y
export UCX_LOG_LEVEL=DEBUG
export OMPI_MCA_btl="^openib,tcp"
flux run -N2 --env UCX_TLS=rc_x,sm,self --env OMPI_MCA_pml=ucx --env UCX_NET_DEVICES=mlx5_0:1 -n2 osu_latency

# We also should test this - this helped on Azure
export UCX_IB_MLX5_DEVX=y

export OMPI_MCA_opal_common_ucx_opal_mem_hooks=1
export OMPI_MCA_btl_openib_allow_ib=true
export UCX_NET_DEVICES=mlx5_0:1
export UCX_TLS=rc,sm,self
export OMPI_MCA_pml=ucx
export OMPI_MCA_osc=ucx
flux run -N2 -n96 lmp -v x 8 -v y 8 -v z 8 -in in.reaxc.hns -nocite
```

### GPUs

You can install the [ROCm/k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin) to expose GPU devices to your pods.

```bash
# Install the driver plugin
kubectl create -f https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml

# Create a test workflow that uses GPU (takes a bit to pull)
https://raw.githubusercontent.com/ROCm/k8s-device-plugin/763445e18f3838fa72b22e31a04ec25987334bff/example/pod/pytorch-non-privileged.yaml

# Get logs (it takes a while to pull...)
kubectl logs alexnet-tf-gpu-pod alexnet-tf-gpu-container
```


### Debugging

Calico: In u7s this address should be same as host:

```bash
bridge fdb show dev vxlan.calico
```
```console
# "this address"
66:63:44:f3:b6:76 dst 192.168.128.222 self permanent
```

If you see the container interface (10.0.x) this is a bug. It could be that the calico-node daemonset still has the `IP` environment variable set to autodetect (which will clobber any changes you make) or you did not issue all the commands in the sync external ip script, or the daemonset to run ethtool.