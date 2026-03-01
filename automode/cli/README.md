# GPU Fine-Tuning Static Node Pool

This directory contains Kubernetes manifests for a static-capacity node pool optimized for fine-tuning workloads on p5.48xlarge instances with On-Demand Capacity Reservations (ODCR).

## Prerequisites

- eksctl installed (version 0.196.0 or later for Auto Mode support)
- kubectl configured to access your cluster
- AWS CLI configured with appropriate permissions
- On-Demand Capacity Reservation for p5.48xlarge instances (see setup below)

## Create EKS Auto Mode Cluster

Create an EKS cluster with Auto Mode enabled using eksctl:

```bash
export CLUSTER_NAME=benchmark-test-cluster
export AWS_REGION=us-east-1
```

```bash
eksctl create cluster --name=$CLUSTER_NAME --region=$AWS_REGION --enable-auto-mode
```

### Install EFA Device Plugin for Auto Mode

Auto Mode supports EFA, but the EFA device plugin must be installed manually:

```bash
kubectl apply -f efa-device-plugin.yaml
```

Verify the EFA device plugin is running:

```bash
kubectl get daemonset -n kube-system aws-efa-k8s-device-plugin-daemonset
kubectl get pods -n kube-system -l name=aws-efa-k8s-device-plugin
```

**IMPORTANT**: As of EKS Auto Mode v1.32, EFA network interfaces are NOT automatically attached to P5 instances, even when the `vpc.amazonaws.com/efa: Exists` requirement is specified in the NodePool. The `vpc.amazonaws.com/efa` label appears on nodes, but the actual EFA hardware is missing.

**Current Status**: EFA support in Auto Mode appears incomplete. The workaround is to use Managed Node Groups with `efaEnabled: true` instead of Auto Mode NodePools for EFA workloads.

Verify the `vpc.amazonaws.com/efa` resource is available (this will be empty until EFA is properly configured):

```bash
kubectl get nodes -o json | jq '.items[].status.capacity | select(.["vpc.amazonaws.com/efa"] != null) | .["vpc.amazonaws.com/efa"]'
```

This command takes a few minutes to complete. After completion, eksctl automatically updates your kubeconfig and targets your newly created cluster. To verify that the cluster is operational, use the following:

```
kubectl get pods --all-namespaces
```

Sample output:

```
NAMESPACE     NAME                                  READY   STATUS    RESTARTS   AGE
kube-system   metrics-server-6d67d68f67-7x4tg       1/1     Running   0          3m
kube-system   metrics-server-6d67d68f67-l4xv6       1/1     Running   0          3m
```

## Create On-Demand Capacity Reservation (ODCR)

To ensure GPU instance availability, create an On-Demand Capacity Reservation:

### Option 1: Using AWS Console

1. Navigate to the EC2 console → Capacity Reservations → Create capacity reservation
2. Configure the reservation with the following settings:
   - **Instance type**: `p5.48xlarge` (must match the GPU instance type used in the nodepool)
   - **Platform**: Linux/UNIX
   - **Availability Zone**: Select any available zone in your region (must match your EKS cluster subnets)
   - **Instance count**: 1 (must match the `replicas` value in nodepool.yaml)
   - **Reservation ends**: Select "Specific time" and set the date to 3 hours from now (or select "Manually" if you want to control when to end the reservation)
   - **Instance eligibility**: "Open" (allows any account with access to use the reservation)
3. Click **Create**
4. Note the Capacity Reservation ID (format: `cr-xxxxxxxxxxxxxxxxx`) for use in the setup steps below

### Option 2: Using AWS CLI

```bash
# Calculate end date (1 hours from now) - macOS compatible
END_DATE=$(date -u -v+1H +"%Y-%m-%dT%H:%M:%S.000Z")
CR_AZ="us-east-1a"
```

Create the Capacity Reservation
Note: If the command succeeds it will result in 1h charge for p5.48xl (~$55)

```
aws ec2 create-capacity-reservation \
  --instance-type p5.48xlarge \
  --instance-platform Linux/UNIX \
  --availability-zone "$CR_AZ" \
  --instance-count 1 \
  --instance-match-criteria open \
  --end-date-type limited \
  --end-date "$END_DATE"
```

Expected result, option 1:

```
An error occurred (InsufficientInstanceCapacity) when calling the CreateCapacityReservation operation (reached max retries: 2): Insufficient capacity.
```

Change the az and retry.

Note the `CapacityReservationId` from the output.

## Setup Instructions

### 1. Get and Validate Capacity Reservation ID

```bash
CAPACITY_RESERVATION_ID=$(aws ec2 describe-capacity-reservations \
  --filters "Name=state,Values=active" "Name=instance-type,Values=p5.48xlarge" \
  --query 'CapacityReservations[0].CapacityReservationId' \
  --output text)

echo "Capacity Reservation ID: $CAPACITY_RESERVATION_ID"
```

### 2. Update the `nodeclass.yaml` with the CapacityReservationId

```bash
envsubst < nodeclass.yaml
```

Validate file is updated with capacity reservation:

```
cat nodeclass.yaml | grep -A 2 "capacityReservationSelectorTerms"
```

Expected output:

```yaml
capacityReservationSelectorTerms:
  - id: cr-xxxxxxxxxxxxxxxxx
```

### 3. Apply NodeClass

```bash
kubectl apply -f nodeclass.yaml
```

### 4. Validate NodeClass Creation

```bash
kubectl get nodeclass gpu-fine-tuning-with-odcr
```

Expected output:

```
NAME                          READY
gpu-fine-tuning-with-odcr     True
```

### 5. Apply NodePool

```bash
kubectl apply -f nodepool.yaml
```

### 6. Validate NodePool Creation

```bash
kubectl get nodepool gpu-fine-tuning-static
```

Expected output:

```
NAME                      REPLICAS   NODES   READY
gpu-fine-tuning-static    1          0       True
```

Note: NODES will show 0 initially, then 1 after the node is provisioned (5-10 minutes).

### 7. Verify Node Provisioning

#### Check NodeClass Status

```bash
kubectl get nodeclass gpu-fine-tuning-with-odcr -o yaml
```

Expected output should show:

- `status.conditions` with `Ready: True`
- `status.subnets` populated with subnet IDs
- `status.securityGroups` populated with security group IDs

#### Check NodePool Status

```bash
kubectl get nodepool gpu-fine-tuning-static
```

Expected output:

```
NAME                      REPLICAS   NODES   READY
gpu-fine-tuning-static    1          1       True
```

#### Verify Node is Running

Wait for the node to be provisioned (may take 5-10 minutes):

```bash
kubectl get nodes -l workload=fine-tuning -w
```

Expected output should show 1 node with:

- Status: `Ready`
- Instance type: `p5.48xlarge`
- 8 GPUs available

#### Check Node Details

```bash
kubectl describe node -l workload=fine-tuning
```

Verify:

- ✅ Taints: `nvidia.com/gpu:NoSchedule`
- ✅ Labels: `workload=fine-tuning`, `gpu=nvidia-h100`
- ✅ Capacity: `nvidia.com/gpu: 8`
- ✅ Allocatable: `nvidia.com/gpu: 8`

### Install MPI operator

https://github.com/aws-samples/aws-do-eks/tree/main/Container-Root/eks/deployment/kubeflow/mpi-operator

export REGISTRY="public.ecr.aws/hpc-cloud/"
export IMAGE="efa"
export TAG=":h100"
export INSTANCE_TYPE="p5.48xlarge"
export GPU_PER_INSTANCE="8"
export GPU_TOTAL="16"
export EFA_PER_INSTANCE="32"
export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/nvidia/nvda_nixl/lib/x86_64-linux-gnu:/opt/nvidia/nvda_nixl/lib/x86_64-linux-gnu/plugins:/usr/local/ucx/lib:/usr/local/ucx/lib/ucx:/usr/local/lib:/usr/local/cuda/compat/lib"

### 8. Test with a Sample Pod

Deploy a test pod to verify GPU access:

```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  nodeSelector:
    workload: fine-tuning
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

Check the pod logs:

```bash
kubectl logs nvidia-smi
```

Expected output should show NVIDIA GPU information for H100 GPUs.

## Configuration Details

### NodeClass: `gpu-fine-tuning-with-odcr`

- Uses On-Demand Capacity Reservation
- Configured for EKS cluster security groups
- Tagged for fine-tuning workloads

### NodePool: `gpu-fine-tuning-static`

- **Static capacity**: Maintains exactly 1 p5.48xlarge node
- **Instance type**: p5.48xlarge (192 vCPUs, 2TB RAM, 8x H100 GPUs)
- **Capacity type**: On-demand with ODCR
- **Node limit**: 1 (matches ODCR capacity)
- **Disruption**: Node replacements will cause brief downtime (no temporary scaling available)

## Scaling

To change the number of static nodes:

```bash
kubectl scale nodepool gpu-fine-tuning-static --replicas=<desired-count>
```

Note: Ensure your capacity reservation has sufficient capacity for the desired replica count.

## Troubleshooting

### Node not provisioning

Check NodePool events:

```bash
kubectl describe nodepool gpu-fine-tuning-static
```

Common issues:

- Capacity reservation ID is incorrect or inactive
- Insufficient capacity in the reservation
- Security group or subnet configuration issues

### Node stuck in NotReady state

Check node conditions:

```bash
kubectl describe node -l workload=fine-tuning
```

### Pods not scheduling

Verify:

1. Pod has correct tolerations for `nvidia.com/gpu` taint
2. Pod has correct nodeSelector: `workload: fine-tuning`
3. Pod requests GPUs: `nvidia.com/gpu: <count>`

## Cleanup

To remove the node pool and node class:

```bash
# Delete test pod if still running
kubectl delete pod nvidia-smi

# Delete NodePool (will drain and terminate nodes)
kubectl delete nodepool gpu-fine-tuning-static

# Delete NodeClass
kubectl delete nodeclass gpu-fine-tuning-with-odcr
```
