# Usernetes as a User Service

We were having trouble with interactive and ssh execution, so I am testing writing a systemctl user service.
For this to work, add each of the .service files to `~/.config/systemd/user` and then do the following.

## Layout

- `usernetes-common.sh`: shared setup sourced by both start scripts (home and PATH, kubectl, rabbit storage discovery, podman storage.conf, template copy, image builds, stale cleanup).
- `usernetes-start-control-plane.sh`: common setup, then `kubeadm-init`, kubeconfig, untaint, and copying the join command to the shared filesystem.
- `usernetes-start-worker.sh`: common setup, then `kubeadm-join` using the shared join command.
- `usernetes-control-plane.service` / `usernetes-worker.service`: the user units. Every knob is an environment variable documented at the top of `usernetes-common.sh` and can be set with an `Environment=` line in the unit.

## Storage (rabbit)

Each physical node has its own rabbit (NNF) storage mounted at `/mnt/nnf/<uuid>-N`, and podman storage has to live there rather than in `$HOME`, which is shared across nodes. On start, each service:

1. Looks under `/mnt/nnf` (override with `USERNETES_RABBIT_MOUNT`) and expects exactly one directory. Zero or more than one is an error. Set `USERNETES_STORAGE_ROOT` to skip discovery, for example on a node without a rabbit.
2. Writes a per-node `storage.conf` into a containers config directory on the rabbit and selects it with `XDG_CONFIG_HOME`. That is the same lookup podman uses for `~/.config/containers/storage.conf`, so the file behaves exactly like a hand-made one, and the shared `~/.config/containers` is never modified. Your other files there (containers.conf, registries.conf) are copied alongside so they stay in effect. The generated file has only the paths changed:

   ```
   [storage]
     driver = "vfs"
     runroot = "/mnt/nnf/<uuid>-0/usernetes/run-<uid>/containers"
     graphroot = "/mnt/nnf/<uuid>-0/usernetes/config/containers/storage"
   [storage.options.vfs]
     ignore_chown_errors = "true"
   ```
3. Verifies with `podman info` that the graphroot really is on the rabbit before building any images.

The layout under the rabbit is:

```
/mnt/nnf/<uuid>-0/usernetes/
├── run-<uid>/containers/            # runroot
└── config/                          # XDG_CONFIG_HOME
    └── containers/
        ├── storage.conf             # generated
        ├── containers.conf, ...     # copied from ~/.config/containers
        └── storage/                 # graphroot (images, layers, compose volumes)
```

If podman rejects the runroot as longer than 50 characters, set `USERNETES_RUNROOT_SYMLINK=1` and the runroot is referenced through a short symlink `/tmp/$USER/.nnf` that points at `<rabbit>/usernetes`; the data stays on the rabbit.

The driver defaults to `vfs`; set `USERNETES_STORAGE_DRIVER=overlay` to try native rootless overlay.

## Debugging and testing

If both nodes are Ready and every pod is Running but pods on different nodes cannot reach each other, check Calico's addressing. Calico only autodetects its VXLAN endpoint when calico-node starts, so if `make install-cni` ran before `make sync-external-ip` covered a node, that node's calico-node keeps the unroutable podman bridge address. This replaces the `calicoctl patch node` step from the earlier test-calico branch.

```bash
cd /tmp/$USER/usernetes && . source_env.sh
/usr/workspace/usernetes/service/check-calico.sh                # report host IP vs. what Calico detected, per node
/usr/workspace/usernetes/service/check-calico.sh --fix            # sync-external-ip, restart calico-node where wrong, re-check
```

If a service fails at the "podman is not using the rabbit storage" check, run the debug script on that node. It does exactly what the service does (discover the rabbit, write storage.conf into the per-node config dir, export `XDG_CONFIG_HOME` and `XDG_RUNTIME_DIR`) and then drives podman through real operations with that config, checking after each that the data landed on the rabbit: `podman info` (config file, driver, graphroot, runroot), `podman images` (creates the libpod database on the rabbit), a volume, an imported image, and a `FROM scratch` build with the service's userns flags. None of those need a registry. When a step fails it prints diagnostics: whether podman's pause process and `podman unshare` can see the rabbit at all (a pause process created before the rabbit was mounted cannot, and `--migrate` replaces it), the podman debug log, which config and database files podman opens (strace), other storage.conf files that could be in play, the libpod database podman complained about, and a retry with explicit `--root`/`--runroot` flags.

```bash
/usr/workspace/usernetes/service/debug-storage.sh            # write config, exercise podman
/usr/workspace/usernetes/service/debug-storage.sh --migrate  # podman system migrate first (replaces the pause process)
/usr/workspace/usernetes/service/debug-storage.sh --fresh    # wipe the runtime dir first, like the service does
/usr/workspace/usernetes/service/debug-storage.sh --pull     # also pull and run busybox
/usr/workspace/usernetes/service/debug-storage.sh --keep     # leave the test image and volume on the rabbit
/usr/workspace/usernetes/service/debug-storage.sh --reset    # podman system reset on the rabbit storage only
```

The shell logic can be tested anywhere without podman or a cluster. The test replaces podman, buildah, make, kubectl and podman-compose with stubs, creates a fake `/mnt/nnf` under a temp dir, and exercises discovery, storage.conf generation, the podman check, source_env.sh, both start scripts end to end, and the debug script.

```bash
./service/test-common.sh       # 67 checks
./service/test-common.sh -v    # also print the captured service logs
```

## Usage

### Allocation

Request a flux alloc for the control plane and a worker, for however many minutes or hours you need, with rabbit storage.

```bash
flux alloc --bg -N2 -q pbatch -t 8h
```

### Control Plane

```bash
ssh <control-plane-node>
# For the control plane - start
rm -rf /usr/workspace/usernetes/control-plane.log
systemctl --user start usernetes-control-plane
systemctl --user status usernetes-control-plane
# check log in /usr/workspace/usernetes/control-plane.log
```

Importantly, in the above you need a podman-compose that has the line to add a label for `PODMAN_SYSTEMD_UNIT` commented out. If when you are in the usernetes kubelet container (`make shell`) or a container and `ulimit -l` is not unlimited, Infiniband is unlikely to work.

### Worker

```bash
ssh <worker-node>
rm -rf /usr/workspace/usernetes/worker.log
systemctl --user start usernetes-worker
systemctl --user status usernetes-worker
# check log in /usr/workspace/usernetes/worker.log
```

### Using the cluster (and podman) on a node

Each service writes `/tmp/$USER/usernetes/source_env.sh` right after copying the template, so it exists while images are still building. It exports the runtime dir, `CNI`, and the rabbit-backed `XDG_CONFIG_HOME`; on the control plane it also sets `KUBECONFIG`. Source it in any shell where you want `podman`, `make`, or `kubectl` to see what the service sees.

```bash
cd /tmp/$USER/usernetes
. source_env.sh
podman images        # served from /mnt/nnf/<uuid>-0/usernetes/config/containers/storage
```
```console
[sochat1@hetchy1017:usernetes]$ kubectl get nodes
NAME              STATUS    ROLES           AGE   VERSION
u7s-hetchy1017    NotReady  control-plane   3m20s v1.37.0
u7s-hetchy1018    NotReady  <none>          1m3s  v1.37.0
```

Importantly, the CNI needs to be installed and the ips sync'd after nodes are up. They will all be `NotReady` until then. `CNI=calico` is already exported by `source_env.sh`.

```bash
make install-cni
make sync-external-ip
```
```console
[sochat1@hetchy1017:usernetes]$ kubectl get nodes
NAME              STATUS   ROLES           AGE   VERSION
u7s-hetchy1017    Ready    control-plane   5m    v1.37.0
u7s-hetchy1018    Ready    <none>          3m7s  v1.37.0
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

Our final experiments will be done separately, and these notes likely cleaned up.
