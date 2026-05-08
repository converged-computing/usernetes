# GPUs

You can install the [ROCm/k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin) to expose GPU devices to your pods.

```bash
kubectl create -f https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml
```

# Create a test workflow that uses GPU (takes a bit to pull)

```bash
# test rocminfo, or rocm-smi inside the pod
kubectl apply -f ./service/gpus/pytorch-amd-interactive.yaml
```
When we can figure out the right container, this should work inside (latest segfaults, likely incompatible, and I have not been able to use older versions due to whiteout file issues).

```python
import torch
if torch.cuda.is_available():
  print(f"GPU is available. Device count: {torch.cuda.device_count()}")
  print(f"Device name: {torch.cuda.get_device_name(0)}")
  x = torch.ones(3, 3, device='cuda')
  y = torch.ones(3, 3, device='cuda') * 2
  z = x + y
  print(f"Result of tensor addition on GPU: {z}")
```
