# GPU Inference

Instructions to create an EKS Auto Mode cluster with GPU NodePools optimized for inference workloads.

## Prerequisites

- eksctl >= 0.225.0
- kubectl
- AWS CLI

## Create EKS Auto Mode Cluster

Create an EKS cluster with Auto Mode enabled using eksctl:

```bash
# NOTE: Keep this cluster name consistent throughout the guide. Do not modify.
export CLUSTER_NAME=eks-docs-inf
export AWS_REGION=us-east-2
```

By default, eksctl creates a cluster in 2 AZs. Using all available AZs improves fault tolerance and increases the chances of obtaining GPU capacity. Check the available AZs in your region:

```bash
export AZS=$(aws ec2 describe-availability-zones \
  --region ${AWS_REGION} \
  --query "AvailabilityZones[?ZoneId!='use1-az3' && ZoneId!='usw1-az2' && ZoneId!='cac1-az3'].ZoneName" \
  --output text | tr '\t' ',')
echo $AZS
```

> **Note:** The Availability Zones `use1-az3`, `usw1-az2`, and `cac1-az3` are excluded because [Amazon EKS does not support control plane placement in those zones](https://repost.aws/knowledge-center/eks-cluster-creation-errors). Creating a cluster with subnets in any of these zones results in an `UnsupportedAvailabilityZoneException`.

Expected output:

```
us-east-2a,us-east-2b,us-east-2c
```

In this example we create the cluster across all 3 AZs in us-east-2:

```bash
eksctl create cluster \
  --name=$CLUSTER_NAME \
  --region=$AWS_REGION \
  --enable-auto-mode \
  --zones=$AZS
```

This command takes a few minutes to complete. After completion, eksctl automatically updates your kubeconfig and targets your newly created cluster. To verify that the cluster is operational:

```bash
kubectl get pods --all-namespaces
```

Sample output:

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
kube-system   metrics-server-55cf976ddd-cz2mw   1/1     Running   0          3m
kube-system   metrics-server-55cf976ddd-wrjvv   1/1     Running   0          3m
```

## Create GPU NodePool for Inference

Deploy a GPU NodePool for inference workloads. Creating the following dynamic NodePool does not launch any instances. It defines a template that Karpenter uses to provision GPU nodes on demand when a matching pod is scheduled. This NodePool targets GPU instances in the `g` category with generation greater than 4 (such as G5 and G6e), which offer NVIDIA GPUs suitable for serving a range of model sizes. The taint ensures only GPU-eligible pods are scheduled on these nodes. Including both On-Demand and Spot lets Karpenter pick the most cost-effective option with available capacity.

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-inf-dynamic
spec:
  template:
    metadata:
      labels:
        guide: eks-docs-inf
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
      taints:
        - key: nvidia.com/gpu
          value: Exists
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: eks.amazonaws.com/instance-category
          operator: In
          values: ["g"]
        - key: eks.amazonaws.com/instance-generation
          operator: Gt
          values: ["4"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
  limits:
    cpu: 100
    memory: 100Gi
EOF
```

Validate the NodePool:

```bash
kubectl get nodepools
```

Expected output:

```
NAME              NODECLASS   NODES   READY   AGE
general-purpose   default     0       True    15m
gpu-inf-dynamic   default     0       True    8s
system            default     2       True    15m
```

The `gpu-inf-dynamic` NodePool starts with zero nodes. Karpenter will automatically provision a GPU node when a pod with matching tolerations and resource requests is scheduled.

### Test with a Sample Pod

We will test with a sample pod requesting a single GPU using `nvidia-smi` (NVIDIA System Management Interface), a standard diagnostic tool used to verify GPU availability, driver versions, and device health. When we deploy the following sample pod, Auto Mode will provision a GPU node and the NVIDIA device plugin will expose GPUs to the container runtime:

```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
  labels:
    guide: eks-docs-inf
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  containers:
  - name: nvidia-smi
    image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: OnFailure
EOF
```

Verify the pod is scheduled and completed successfully.

```bash
kubectl get pods
```

Expected output:

```
NAME         READY   STATUS      RESTARTS   AGE
nvidia-smi   0/1     Completed   0          71s
```

The `STATUS: Completed` means the `nvidia-smi` command ran and exited. Check the pod logs to see the GPU detected by the node.

```bash
kubectl logs nvidia-smi
```

Expected output:

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.126.09             Driver Version: 580.126.09     CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA RTX PRO 6000 Blac...    On  |   00000000:2B:00.0 Off |                    0 |
| N/A   30C    P0             81W /  600W |       0MiB /  97887MiB |      0%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+
```

The output shows the GPU model, driver version, CUDA version, and available memory. The GPU model and memory will vary depending on the instance type Karpenter selects (for example, G5 instances have NVIDIA A10G GPUs while G6e instances have NVIDIA L40S GPUs).

Use `kubectl describe` to see the full pod lifecycle events. This is useful for understanding how Karpenter and the scheduler coordinated to provision a node and place the pod:

```bash
kubectl describe po nvidia-smi
```

Expected output:

```
Events:
  Type     Reason                  Age   From                   Message
  ----     ------                  ----  ----                   -------
  Warning  FailedScheduling        67s   default-scheduler      0/2 nodes are available: 2 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
  Normal   Nominated               67s   eks-auto-mode/compute  Pod should schedule on: nodeclaim/gpu-inf-dynamic-ggsvc
  Normal   Scheduled               31s   default-scheduler      Successfully assigned default/nvidia-smi to i-01ea29a35bb334680
  Normal   Pulling                 10s   kubelet                spec.containers{nvidia-smi}: Pulling image "public.ecr.aws/amazonlinux/amazonlinux:2023-minimal"
  Normal   Pulled                  8s    kubelet                spec.containers{nvidia-smi}: Successfully pulled image "public.ecr.aws/amazonlinux/amazonlinux:2023-minimal" in 1.475s (1.475s including waiting). Image size: 37442365 bytes.
  Normal   Created                 8s    kubelet                spec.containers{nvidia-smi}: Created container: nvidia-smi
  Normal   Started                 8s    kubelet                spec.containers{nvidia-smi}: Started container nvidia-smi
```

The events show the pod scheduling sequence: the pod initially fails to schedule because no GPU nodes exist (`FailedScheduling`), Karpenter nominates a new NodeClaim (`Nominated`), the scheduler assigns the pod once the node is ready (`Scheduled`), and then the container image is pulled and started.

Verify the node is provisioning by checking the NodeClaim, NodePool, and nodes.

A NodeClaim is a request Karpenter creates to provision a specific node. It shows the instance type, capacity type, AZ, and whether the node is ready:

Check the node details:

```bash
kubectl get nodes -o wide
```

Expected output should show a GPU node with the Bottlerocket Nvidia AMI:

```
NAME                  STATUS   ROLES    AGE     VERSION               INTERNAL-IP       EXTERNAL-IP   OS-IMAGE                                                              KERNEL-VERSION   CONTAINER-RUNTIME
i-01xxxxxxxxxxxxxxx   Ready    <none>   56s     v1.34.4-eks-f69f56f   192.168.151.199   <none>        Bottlerocket (EKS Auto, Nvidia) 2026.4.23 (aws-k8s-1.34-nvidia)       6.12.79          containerd://2.1.6+bottlerocket
```

The `OS-IMAGE` column shows `Bottlerocket (EKS Auto, Nvidia)`, which is the accelerated Bottlerocket AMI variant with pre-installed NVIDIA drivers and device plugins. EKS Auto Mode automatically selected this AMI because the pod requested a GPU resource, without requiring any additional AMI configuration or launch templates. Karpenter will automatically remove the node 30 seconds after no pod is running, so if the job completed but no node shows up, that is expected.

Check the `gpu-inf-dynamic` NodePool to validate Karpenter provisioned the instance from it:

```bash
kubectl get nodepools gpu-inf-dynamic
```

Expected output:

```
NAME              NODECLASS   NODES   READY   AGE
gpu-inf-dynamic   default     1       True    5m
```

`NODES: 1` means Karpenter provisioned one node from this NodePool. If `NODES: 0`, either the pod hasn't triggered provisioning yet or the node was already removed after the job completed.

Check the NodeClaim to see the specific instance Karpenter launched. A NodeClaim represents a single node provisioning request and shows the instance type, capacity type, and AZ that Karpenter selected:

```bash
kubectl get nodeclaims
```

Expected output:

```
NAME                    TYPE          CAPACITY    ZONE         NODE                  READY   AGE
gpu-inf-dynamic-xxxxx   g7e.2xlarge   spot        us-east-2b   i-0xxxxxxxxxxxx       True    2m
```

Here Karpenter picked a `g7e.2xlarge` Spot instance in `us-east-2b`. The instance type and AZ will vary based on what capacity is available at the time.

If the pod is not scheduling and no node appears, check for Insufficient Capacity Errors (ICE). An ICE occurs when the requested instance type is temporarily unavailable in the targeted Availability Zone:

```bash
kubectl get events | grep InsufficientCapacityError
```

If you see an ICE, the output will look similar to:

```
3m7s   Warning   InsufficientCapacityError   nodeclaim/gpu-inf-dynamic-xxxxx   Unable to fulfill capacity due to your request configuration. Please adjust your request and try again.
```

Karpenter will automatically retry across available AZs. When it receives an ICE, it caches that specific offering (instance type + AZ + capacity type) as unavailable for 3 minutes, then retries. Other offerings remain eligible, so widening the set of allowed instance types and AZs in your NodePool increases the chances of landing capacity.

> **Note:** Spot instances launched by Karpenter will not appear in the EC2 Spot Requests console. Karpenter uses the EC2 `CreateFleet` API with `type: instant`, which provisions instances synchronously without creating a Spot Request object. The instances appear in the normal EC2 Instances console with a `spot` lifecycle.

## Use On-Demand Capacity Reservation (ODCR) with Spot Overflow

This section sets up two NodePools: a static ODCR-backed NodePool (`gpu-inf-static`) for guaranteed capacity, and the dynamic Spot/On-Demand NodePool (`gpu-inf-dynamic`) created earlier as overflow. The ODCR node is provisioned immediately, so the scheduler places pods there first. When the ODCR node is full, additional pods go Pending and Karpenter provisions Spot/On-Demand nodes from the dynamic `gpu-inf-dynamic` NodePool.

### Create the Capacity Reservation

```bash
# Calculate end date (1 hour from now) - macOS compatible
END_DATE=$(date -u -v+1H +"%Y-%m-%dT%H:%M:%S.000Z")
CR_AZ="us-east-2a"
```

> **Note**: If the command succeeds it will result in a charge for the reserved instance type for the duration of the reservation.

```bash
aws ec2 create-capacity-reservation \
  --instance-type g6e.2xlarge \
  --instance-platform Linux/UNIX \
  --availability-zone "$CR_AZ" \
  --instance-count 1 \
  --instance-match-criteria open \
  --end-date-type limited \
  --end-date "$END_DATE"
```

If you get an `InsufficientInstanceCapacity` error, change the AZ and retry.

### Get and Validate Capacity Reservation ID

```bash
CAPACITY_RESERVATION_ID=$(aws ec2 describe-capacity-reservations \
  --filters "Name=state,Values=active" "Name=instance-type,Values=g6e.2xlarge" \
  --query 'CapacityReservations[0].CapacityReservationId' \
  --output text)

echo "Capacity Reservation ID: $CAPACITY_RESERVATION_ID"
```

### Apply NodeClass with Capacity Reservation

```bash
cat << EOF | kubectl apply -f -
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: gpu-inf-static
spec:
  ephemeralStorage:
    size: "200Gi"
  capacityReservationSelectorTerms:
    - id: "$CAPACITY_RESERVATION_ID"
EOF
```

Validate:

```bash
kubectl get nodeclass gpu-inf-static
```

Expected output:

```
NAME              READY
gpu-inf-static    True
```

### Apply Static ODCR NodePool

This NodePool provisions a node immediately using the capacity reservation. It uses `replicas: 1` to keep one node running at all times.

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: eks.amazonaws.com/v1
kind: NodePool
metadata:
  name: gpu-inf-static
spec:
  replicas: 1
  template:
    metadata:
      labels:
        workload: inference
        capacity: odcr
        guide: eks-docs-inf
    spec:
      nodeClassRef:
        name: gpu-inf-static
      requirements:
        - key: "node.kubernetes.io/instance-type"
          operator: In
          values: ["g6e.2xlarge"]
        - key: "eks.amazonaws.com/capacity-type"
          operator: In
          values: ["on-demand"]
      taints:
        - key: "nvidia.com/gpu"
          effect: NoSchedule
EOF
```

### Validate NodePool and Node Provisioning

```bash
kubectl get nodepools
```

Expected output:

```
NAME              NODECLASS        NODES   READY   AGE
general-purpose   default          0       True    20m
gpu-inf-dynamic   default          0       True    10m
gpu-inf-static    gpu-inf-static   0       True    8s
system            default          2       True    20m
```

Wait for the ODCR node to provision (may take 5-10 minutes):

```bash
kubectl get nodes -o wide -w
```

Expected output should show the ODCR node with the Bottlerocket Nvidia AMI:

```
NAME              STATUS   ROLES    AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                                                           CONTAINER-RUNTIME
i-0xxxxxxxxxxxx   Ready    <none>   2m    v1.32     10.0.x.x       <none>        Bottlerocket (EKS Auto, Nvidia) 2025.x.x (aws-k8s-1.32-nvidia)     containerd://x.x.x
```

### How Scheduling Works Across Both NodePools

Both NodePools use the same `nvidia.com/gpu` taint. A pod that tolerates this taint and requests GPUs can land on either:

1. The ODCR node is already running → scheduler places the pod there first
2. If the ODCR node is full, the pod goes Pending → Karpenter provisions a Spot/On-Demand node from the `gpu-inf-dynamic` NodePool

No affinity rules are needed. The scheduler naturally prefers existing nodes over triggering new provisioning.

## Cleanup

```bash
# Delete test pod if still running
kubectl delete pod nvidia-smi

# Delete dynamic NodePool
kubectl delete nodepool gpu-inf-dynamic

# Delete ODCR NodePool (will drain and terminate the node)
kubectl delete nodepool gpu-inf-static

# Delete ODCR NodeClass
kubectl delete nodeclass gpu-inf-static

# Delete the cluster
eksctl delete cluster --name=$CLUSTER_NAME --region=$AWS_REGION
```

## Troubleshooting

### Node not provisioning

Check NodePool events:

```bash
kubectl describe nodepool gpu-inf-static
```

Common issues:

- Capacity reservation ID is incorrect or inactive
- Insufficient capacity in the reservation
- Security group or subnet configuration issues

### Node stuck in NotReady state

Check node conditions:

```bash
kubectl describe node -l workload=inference
```
