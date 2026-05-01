# GPU Fine-Tuning

This directory contains Kubernetes manifests for EKS Standard cluster with OSS Karpenter and NodePool optimized for fine-tuning workloads.

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2, configured with permissions to create EKS clusters, VPCs, and IAM roles
- [eksctl](https://eksctl.io/) >= 0.196.0 (for Auto Mode support, tested with 0.224.0)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) >= 1.34
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5

## Check Spot Placement Scores - for the test we will use Spot Capacity, for actual Training workloads, we recommend Reserved Capacity

Before requesting Spot GPU instances, check [Spot placement scores](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html) to find which regions and Availability Zones have the best capacity for your target instance types. Scores range from 1 (low likelihood) to 10 (high likelihood) of getting your requested capacity.

Set the instance types and regions you want to check:

```bash
TYPES=("p5.48xlarge" "p5e.48xlarge" "p5en.48xlarge")
REGIONS=("us-east-1" "us-east-2" "us-west-2")
```

Run the score check across all combinations:

```bash
for type in "${TYPES[@]}"; do
  echo "=== $type ==="
  aws ec2 get-spot-placement-scores \
    --instance-types "$type" \
    --target-capacity 1 \
    --region-names "${REGIONS[@]}" \
    --single-availability-zone \
    --query 'SpotPlacementScores | sort_by(@, &AvailabilityZoneId)' \
    --output table
done
```

Example output:

```
=== p5.48xlarge in us-east-2 ===
------------------------------------------------
|            GetSpotPlacementScores            |
+----------------------------------------------+
||             SpotPlacementScores            ||
|+---------------------+-------------+--------+|
|| AvailabilityZoneId  |   Region    | Score  ||
|+---------------------+-------------+--------+|
||  use2-az2           |  us-east-2  |  2     ||
||  use2-az3           |  us-east-2  |  1     ||
||  use2-az1           |  us-east-2  |  9     ||
|+---------------------+-------------+--------+|
```

In this example, `use2-az1` scores a 9, meaning there's a high likelihood of getting a `p5.48xlarge` Spot instance there. `use2-az3` scores a 1, meaning capacity is scarce. Use this to target your workloads toward AZs with higher scores.

**Note:** A higher score doesn't guarantee capacity. It reflects the likelihood based on recent Spot availability trends. Scores reflect recent Spot availability trends and don't guarantee capacity. Check scores close to when you plan to launch.

## Create EKS Standard Cluster using Terraform from ai-on-eks

### Clone and setup

Clone [ai-on-eks](https://github.com/awslabs/ai-on-eks) repository:

```bash
git clone git@github.com:awslabs/ai-on-eks.git
cd ai-on-eks/infra
```

Create a test folder (the following section is temp and a folder will be provided in the polished version):

```bash
mkdir -p test/terraform
```

Create `test/install.sh`:

```bash
cat > test/install.sh << 'EOF'
#!/bin/bash
# Copy the base into the folder
mkdir -p ./terraform/_LOCAL
cp -r ../base/terraform/* ./terraform/_LOCAL

cd terraform/_LOCAL
source ./install.sh
EOF
chmod +x test/install.sh
```

### Configure the cluster

Set environment variables:

```bash
export CLUSTER_NAME=bench-test
export AWS_REGION=us-east-2
```

> **Note:** Keep the cluster name under 18 characters. The Karpenter module prepends `KarpenterController-` (20 chars) to create IAM role names, and AWS IAM `name_prefix` has a 38 character limit.
> TODO: Truncate iam role at 38 char

Create `test/terraform/blueprint.tfvars`:

```bash
cat > test/terraform/blueprint.tfvars << EOF
name                            = "${CLUSTER_NAME}"
enable_argocd                   = true
availability_zones_count        = 3
region                          = "${AWS_REGION}"
eks_cluster_version             = "1.34"
EOF
```

### Create the cluster

```bash
cd test
./install.sh
```

This will create an EKS cluster with essential addons and OSS Karpenter. The cluster will have CPU instances for the addons but will not launch any GPU instances unless requested via a NodePool.

Expected output:

```
Apply complete! Resources: 37 added, 0 changed, 0 destroyed.

Outputs:

configure_kubectl = "aws eks --region us-east-2 update-kubeconfig --name bench-test"
deployment_name = "bench-test"

SUCCESS: Terraform apply of all modules completed successfully
```

Run the `configure_kubectl` command from the output to set up kubectl access:

```bash
aws eks --region us-east-2 update-kubeconfig --name bench-test --alias bench-test
```

> TODO: add `--alias <cluster name>` to tf output

### Verify

```bash
kubectl get pods --all-namespaces
```

Expected output should include karpenter pods:

```
NAMESPACE              NAME                                                              READY   STATUS    RESTARTS   AGE
amazon-cloudwatch      amazon-cloudwatch-observability-controller-manager-78c74649bbfj   1/1     Running   0          5m13s
amazon-cloudwatch      cloudwatch-agent-k5nzv                                            1/1     Running   0          5m10s
amazon-cloudwatch      cloudwatch-agent-rj4tj                                            1/1     Running   0          5m10s
amazon-cloudwatch      fluent-bit-dd7nv                                                  1/1     Running   0          5m13s
amazon-cloudwatch      fluent-bit-sk9ms                                                  1/1     Running   0          5m13s
argocd                 argocd-application-controller-0                                   1/1     Running   0          2m10s
argocd                 argocd-applicationset-controller-d76f9bd8b-ftgmf                  1/1     Running   0          2m11s
argocd                 argocd-redis-67b65f656-56hfn                                      1/1     Running   0          2m11s
argocd                 argocd-repo-server-b6494f8cf-9r75c                                1/1     Running   0          2m11s
argocd                 argocd-server-654f7c6984-rbn9n                                    1/1     Running   0          2m10s
kube-system            aws-load-balancer-controller-5f4765cff7-5gwzm                     1/1     Running   0          100s
kube-system            aws-load-balancer-controller-5f4765cff7-7dnjp                     1/1     Running   0          100s
kube-system            aws-node-m72m2                                                    2/2     Running   0          5m57s
kube-system            aws-node-pqkw5                                                    2/2     Running   0          5m56s
kube-system            coredns-9b4556f76-l642s                                           1/1     Running   0          5m19s
kube-system            coredns-9b4556f76-rlgtt                                           1/1     Running   0          5m19s
kube-system            ebs-csi-controller-89bfc9c9d-6b4jw                                6/6     Running   0          3m5s
kube-system            ebs-csi-controller-89bfc9c9d-zvknk                                6/6     Running   0          3m5s
kube-system            ebs-csi-node-4m8z8                                                3/3     Running   0          3m5s
kube-system            ebs-csi-node-qdq76                                                3/3     Running   0          3m5s
kube-system            eks-node-monitoring-agent-chcm6                                   1/1     Running   0          5m20s
kube-system            eks-node-monitoring-agent-ff72w                                   1/1     Running   0          5m20s
kube-system            eks-pod-identity-agent-4nqdz                                      1/1     Running   0          5m56s
kube-system            eks-pod-identity-agent-d654b                                      1/1     Running   0          5m57s
kube-system            k8s-neuron-scheduler-7865c4d9c8-pmqnc                             1/1     Running   0          97s
kube-system            karpenter-68874cd595-5zpqg                                        1/1     Running   0          3m7s
kube-system            karpenter-68874cd595-dz25s                                        1/1     Running   0          3m7s
kube-system            kube-proxy-6m6hs                                                  1/1     Running   0          5m20s
kube-system            kube-proxy-jhfl6                                                  1/1     Running   0          5m20s
kube-system            metrics-server-55cf976ddd-9ltfc                                   1/1     Running   0          5m18s
kube-system            metrics-server-55cf976ddd-np62w                                   1/1     Running   0          5m18s
kube-system            neuron-scheduler-7c88f4f548-d4bvn                                 1/1     Running   0          97s
nvidia-device-plugin   nvidia-device-plugin-node-feature-discovery-gc-774f49fdcb-4s59k   1/1     Running   0          97s
nvidia-device-plugin   nvidia-device-plugin-node-feature-discovery-master-b6ffb565cxnq   1/1     Running   0          97s
nvidia-device-plugin   nvidia-device-plugin-node-feature-discovery-worker-4pl4m          1/1     Running   0          97s
nvidia-device-plugin   nvidia-device-plugin-node-feature-discovery-worker-pzzj5          1/1     Running   0          97s
```

## Create a dynamic test Spot H100 NodePool with Default NodeClass

```
kubectl apply -f automode/cli/spot-p-nodepool.yaml
```

This command creates a dynamic Spot NodePool using the default NodeClass that starts with 0 instances and scales up only when a workload is scheduled. The NodePool is configured to scale down to 0 when idle and up to a maximum of 2 Spot p5.48xlarge instances.

Validate NodePools is created:

```
kubectl get nodepools spot-p
```

Expected output:

```
NAME        NODECLASS   NODES   READY   AGE
spot-p      default     0       True    15s
```

### Test with a Sample Pod

> **Note:** The sample pod below uses the default NodeClass. For the P5 EFA NodePool with FSx Lustre support, see the next section.

`nvidia-smi` (NVIDIA System Management Interface) is a standard diagnostic tool used across the industry to verify GPU availability, driver versions, and device health. Deploy a test pod requesting a single GPU to confirm that Karpenter provisions a GPU node and the NVIDIA device plugin exposes GPUs to the container runtime

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
  containers:
  - name: nvidia-smi
    image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
        vpc.amazonaws.com/efa: 32
  restartPolicy: OnFailure
EOF
```

Check if getting ICEd (Karpenter logs):

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i "insufficient capacity"
```

Or via Kubernetes events:

```bash
kubectl get events --field-selector reason=InsufficientCapacityError
```

If you see:

```
failed launching nodeclaim, creating instance, insufficient capacity, all requested instance types were unavailable during launch
```

Means you are getting ICEd. Karpenter will keep retrying every ~60 seconds.
Check the pod logs:

```bash
kubectl logs nvidia-smi
```

## Create P5 EFA NodePool with FSx Lustre Support

This creates a static P5 NodePool with a custom EC2NodeClass that includes EFA networking, Lustre client, GDS driver, and EFA Lustre configuration.

### Get the Karpenter node role

The Terraform module creates a Karpenter node IAM role. Get its name:

```bash
export KARPENTER_NODE_ROLE=$(aws iam list-roles --query "Roles[?starts_with(RoleName, 'karpenterNode-${CLUSTER_NAME}')].RoleName | [0]" --output text)
echo "Karpenter Node Role: $KARPENTER_NODE_ROLE"
```

### Apply the EC2NodeClass and NodePool

The `p5-efa-ec2nodeclass.yaml` uses `${CLUSTER_NAME}` and `${KARPENTER_NODE_ROLE}` as template variables. Use `envsubst` to substitute and apply:

```bash
envsubst < p5-efa-ec2nodeclass.yaml | kubectl apply -f -
kubectl apply -f p5-efa-nodepool.yaml
```

### Verify

```bash
kubectl get ec2nodeclass p5-efa
kubectl get nodepool p5-efa
```

Expected output:

```
NAME      READY
p5-efa    True

NAME      NODECLASS   NODES   READY   AGE
p5-efa    p5-efa      0       True    15s
```

The node will provision once the NodePool's `replicas: 1` triggers a launch. Check Karpenter logs for progress:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep p5-efa
```

## Install MPI Operator

MPI Operator is an open-source Kubernetes controller from Kubeflow that manages distributed MPI jobs by automating worker pod creation, SSH setup, and `mpirun` orchestration across nodes. To validate multi-instance EFA networking, we need to run a distributed NCCL test (like `all_reduce_perf`) across multiple GPU nodes, which requires MPI to coordinate the communication between workers, and the MPI Operator handles that orchestration on Kubernetes.

> [!NOTE]
> There is no official Helm chart for MPI Operator, only community-maintained (outdated) charts. Kubeflow recommends `kubectl apply`. See the [MPI Operator GitHub repo](https://github.com/kubeflow/mpi-operator) for details.

#### kubectl apply ([official instructions](https://github.com/kubeflow/mpi-operator), recommended)

Install the latest release (v0.8.0) directly from the Kubeflow repo:

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.8.0/deploy/v2beta1/mpi-operator.yaml
```

This installs the operator and the `MPIJob` CRD (`mpijobs.kubeflow.org`) used to run distributed MPI workloads on Kubernetes.

#### Verify installation

Validate `mpi` pod is Running (it might take 30-40s for the pod to be in Running state)

```bash
kubectl get pods -n mpi-operator
```

Expected output:

```
NAME                            READY   STATUS    RESTARTS   AGE
mpi-operator-85f8599757-wz2gp   1/1     Running   0          41s
```

Validate `mpi` CRD was created

```
kubectl get crd | grep mpi
```

Expected output:

```
mpijobs.kubeflow.org
```

## Run MPI Job

```
kubectl apply -f mpijob.yaml
```

```
export REGISTRY="public.ecr.aws/hpc-cloud/"
export IMAGE="efa"
export TAG=":h100"
export INSTANCE_TYPE="p5.48xlarge"
export GPU_PER_INSTANCE="8"
export GPU_TOTAL="16"
export EFA_PER_INSTANCE="32"
export LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/nvidia/nvda_nixl/lib/x86_64-linux-gnu:/opt/nvidia/nvda_nixl/lib/x86_64-linux-gnu/plugins:/usr/local/ucx/lib:/usr/local/ucx/lib/ucx:/usr/local/lib:/usr/local/cuda/compat/lib"
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

![alt text](image.png)

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
