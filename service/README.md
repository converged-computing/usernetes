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
systemctl --user start usernetes-worker
systemctl --user status usernetes-worker
# check log in /usr/workspace/usernetes/worker.log
```

Back on the control plane (if everything looks good) we can go to the copied control plane directory, source a file to get kubectl and the correct paths, and see our cluster.

```bash
. source_env.sh
```
```console
[sochat1@corona190:service]$ kubectl get nodes
NAME            STATUS    ROLES           AGE   VERSION
u7s-corona190   NotReady  control-plane   3m20s v1.30.0
u7s-corona196   NotReady  <none>          1m3s  v1.30.0
```

Importantly, the ips need to be sync'd (and an annotation added for flannel) after nodes are up. They will all be `NotReady`.

```bash
make sync-external-ip
make install-flannel
```
```console
[sochat1@corona190:service]$ kubectl get nodes
NAME            STATUS   ROLES           AGE   VERSION
u7s-corona190   Ready    control-plane   5m    v1.30.0
u7s-corona196   Ready    <none>          3m7s  v1.30.0
```

You can now install the Flux Operator and run experiments, or look at [using gpus](gpus).

```bash
kubectl apply -f https://raw.githubusercontent.com/flux-framework/flux-operator/refs/heads/main/examples/dist/flux-operator.yaml
```

Test away! Good luck.
