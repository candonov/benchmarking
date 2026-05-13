# Set Up Cluster and Nodes (Self-managed Karpenter)

This section walks through creating an EKS standard cluster with a self-managed Karpenter controller and a GPU NodePool equivalent to the [EKS Auto Mode walkthrough](automode.md). Unlike Auto Mode, where AWS manages the control plane components for you, here you install and operate Karpenter yourself.

> **Note:** This walkthrough focuses on reaching parity with the Auto Mode control plane components used later in this guide (Karpenter, NVIDIA device plugin, Pod Identity agent, EKS Node Monitoring Agent, automatic node repair via the Karpenter `NodeRepair` feature gate, and the SOCI snapshotter configured via EC2 user data). It does not install the EBS CSI driver, the default gp3 StorageClass, or the AWS Load Balancer Controller. Add those if your workload requires them.

## Prerequisites

- kubectl >= 1.34
- AWS CLI >= 2.27
- Helm >= 3.14
- jq
- eksctl >= 0.225.0

Verify your eksctl version:

```bash
eksctl version
```

If you are on a version older than 0.225.0, follow the [eksctl installation guide](https://eksctl.io/installation/) to upgrade to the latest release.

eksctl pulls the Karpenter Helm chart from Amazon Public ECR. Authenticate Helm to public ECR before creating the cluster, otherwise the install can fail at the Helm step with a 403 "Your authorization token has expired" error:

```bash
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws
```

> **Note:** Public ECR is a global service hosted in `us-east-1`. Use `--region us-east-1` here regardless of which region your EKS cluster is in.

Expected output:

```
Login Succeeded
```

> **Note:** If you skip this step or the token has expired, `eksctl create cluster` may fail at the Karpenter Helm install step. The cluster itself will be up. See the [Recovering from Karpenter Helm install failure](#recovering-from-karpenter-helm-install-failure) appendix at the end of this section for how to finish the install without recreating the cluster.

## Create EKS Standard Cluster with Karpenter

Set the cluster name and region. Keep this value consistent with the rest of the guide:

```bash
# NOTE: Keep this cluster name value consistent throughout the guide. Changing
# it may cause subsequent commands to target the wrong cluster.
export CLUSTER_NAME=eks-docs-inf
export AWS_REGION=us-east-2
export KARPENTER_VERSION=1.12.0
```

Discover the available AZs. Using all three AZs improves fault tolerance and increases the chances of obtaining GPU capacity:

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

Create a cluster config that installs Karpenter, a small managed node group to host the Karpenter controller itself, and the EKS Pod Identity Agent addon:

```bash
cat << EOF > /tmp/cluster-karpenter.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.35"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

availabilityZones: [$(echo $AZS | sed 's/,/, /g')]

iam:
  withOIDC: true

karpenter:
  version: "${KARPENTER_VERSION}"
  withSpotInterruptionQueue: true

managedNodeGroups:
  - name: system
    instanceType: m5.large
    desiredCapacity: 2
    minSize: 2
    maxSize: 3
    labels:
      role: system
    tags:
      karpenter.sh/discovery: ${CLUSTER_NAME}

addons:
  - name: eks-pod-identity-agent
  - name: eks-node-monitoring-agent
EOF
```

This will create an EKS cluster with a managed node group dedicated to hosting add-ons and the Karpenter controller. Karpenter will be installed with the Spot interruption queue enabled so it can handle Spot interruption and rebalance recommendations. The cluster also gets the EKS Pod Identity Agent and the EKS Node Monitoring Agent installed as managed add-ons. Pod Identity is used later in the guide. The Node Monitoring Agent runs on every node and reads kernel logs to set node conditions such as `AcceleratedHardwareReady`, `KernelReady`, and `NetworkingReady`, which Karpenter automatic node repair uses to decide when to replace an unhealthy node.

Create the cluster:

```bash
eksctl create cluster -f /tmp/cluster-karpenter.yaml
```

This command takes about 15 minutes to complete. It creates the VPC, subnets, IAM roles, the cluster, the managed node group, the addons, and installs Karpenter via Helm. After completion, eksctl updates your kubeconfig automatically.

Verify the cluster is operational:

```bash
kubectl get pods --all-namespaces
```

Expected output includes Karpenter, CoreDNS, kube-proxy, aws-node (VPC CNI), the Pod Identity Agent, and the Node Monitoring Agent:

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
karpenter     karpenter-567547464c-s6vkx        1/1     Running   0          3m40s
karpenter     karpenter-567547464c-x7gmw        1/1     Running   0          3m40s
kube-system   aws-node-b6gf2                    2/2     Running   0          12m
kube-system   aws-node-lcphh                    2/2     Running   0          12m
kube-system   coredns-7d4dcbf4fb-ccvrr          1/1     Running   0          16m
kube-system   coredns-7d4dcbf4fb-qbhk2          1/1     Running   0          16m
kube-system   eks-node-monitoring-agent-h79vm   1/1     Running   0          9m45s
kube-system   eks-node-monitoring-agent-tf4dw   1/1     Running   0          9m45s
kube-system   eks-pod-identity-agent-5jbtc      1/1     Running   0          12m
kube-system   eks-pod-identity-agent-rwcrc      1/1     Running   0          12m
kube-system   kube-proxy-p4bmq                  1/1     Running   0          12m
kube-system   kube-proxy-v5nwr                  1/1     Running   0          12m
kube-system   metrics-server-5b966ff79c-hr58p   1/1     Running   0          9m22s
kube-system   metrics-server-5b966ff79c-szs2d   1/1     Running   0          9m22s
```

## Enable Automatic Node Repair

EKS Auto Mode enables automatic node repair by default. On self-managed Karpenter it is gated behind the `NodeRepair=true` feature gate and must be turned on explicitly. The eksctl `karpenter` ClusterConfig block does not expose Karpenter feature gates, so we patch the deployment after install instead. When enabled, Karpenter reads the node conditions set by the Node Monitoring Agent (`AcceleratedHardwareReady`, `KernelReady`, `NetworkingReady`, `ContainerRuntimeReady`, `StorageReady`) and replaces unhealthy nodes automatically.

Patch the Karpenter deployment to add the `NodeRepair=true` feature gate. Updating the deployment env triggers a rollout of the Karpenter pods:

```bash
kubectl set env deployment/karpenter -n karpenter \
  FEATURE_GATES=NodeRepair=true
```

Expected output:

```
deployment.apps/karpenter env updated
```

Wait for the Karpenter pods to roll out:

```bash
kubectl rollout status deployment/karpenter -n karpenter
```

> **Note:** Auto Mode and self-managed Karpenter share the same auto-repair behavior for nodes provisioned by NodePools. All `AcceleratedHardwareReady` repair actions are `Replace`, since both treat node lifecycle as immutable and don't support in-place reboots. Both also stop repair actions automatically when more than 20% of nodes in a NodePool are unhealthy, to prevent runaway replacement during widespread issues. EKS managed node groups behave differently: they support `Reboot` as a repair action for some XID codes, per the [EKS node repair docs](https://docs.aws.amazon.com/eks/latest/userguide/node-repair.html).
>
> Auto-repair is a **forceful** disruption method. When the toleration duration on an unhealthy condition elapses, Karpenter terminates the node immediately. It bypasses PodDisruptionBudgets, the `karpenter.sh/do-not-disrupt` annotation, and the NodeClaim's `terminationGracePeriod`. NodePool disruption budgets (`spec.disruption.budgets`) also do not gate auto-repair. Those only apply to voluntary disruption methods like drift and consolidation.
>
> The toleration duration before replacement is 10 minutes for `AcceleratedHardwareReady` and 30 minutes for every other monitored condition (`Ready`, `KernelReady`, `NetworkingReady`, `StorageReady`, `ContainerRuntimeReady`).

## Install NVIDIA Device Plugin

The NVIDIA device plugin advertises the `nvidia.com/gpu` resource on GPU nodes so Kubernetes recognizes them as schedulable for GPU pods. The EKS-optimized Bottlerocket Accelerated AMI ships with the device plugin pre-installed, but the EKS-optimized AL2023 NVIDIA AMI does not. Auto Mode uses the Bottlerocket Accelerated AMI for its GPU nodes, which is why no manual install is needed there. This walkthrough uses AL2023, so you install the plugin via Helm.

We mirror the [AI-on-EKS device plugin values](https://github.com/awslabs/ai-on-eks/blob/main/infra/base/terraform/helm-values/nvidia-device-plugin.yaml) so the install behaves the same way as AI-on-EKS clusters: scoped to AL2023 nodes, MOFED disabled (not needed for inference), and GFD plus NFD enabled.

Add the NVIDIA Helm repo:

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
```

Write the values file:

```bash
cat << 'EOF' > /tmp/nvdp-values.yaml
# Disable MOFED
mofedEnabled: false

# Target only nodes running AL2023 AMIs
nodeSelector:
  amiFamily: al2023

# Enable GPU Feature Discovery (default: false)
gfd:
  enabled: true

# Configure Node Feature Discovery components
nfd:
  worker:
    tolerations:
      - operator: "Exists"
EOF
```

What each value does:

- **`mofedEnabled: false`** disables the chart's check for [Mellanox OFED](https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/) drivers. MOFED is for InfiniBand fabrics, which AWS does not use. AWS uses EFA for high-throughput networking, and the EFA driver is independent of MOFED. Leaving this enabled would block the device plugin from becoming Ready while it waits for MOFED that will never appear.
- **`nodeSelector.amiFamily: al2023`** scopes the device plugin DaemonSet to nodes labeled `amiFamily: al2023`. The Bottlerocket Accelerated AMI already includes the device plugin, so we only want this DaemonSet running on AL2023 nodes.
- **`gfd.enabled: true`** turns on GPU Feature Discovery. GFD adds detailed labels to nodes (`nvidia.com/gpu.product`, `nvidia.com/gpu.memory`, `nvidia.com/cuda.driver.major`, etc.) so workloads can target specific GPU models or memory sizes via nodeSelector or affinity. Auto Mode includes GFD by default.
- **`nfd.worker.tolerations`** lets the Node Feature Discovery worker DaemonSet schedule on nodes with any taint, including the `nvidia.com/gpu` taint on your GPU NodePool. NFD scans hardware and software features and surfaces them as node labels that GFD builds on.

Install the chart:

```bash
helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  -f /tmp/nvdp-values.yaml
```

The `amiFamily: al2023` label is not set automatically by EKS. You apply it on the GPU NodePool template in the next section so that nodes Karpenter launches advertise themselves as AL2023, and the device plugin DaemonSet selects them. If you later add a Bottlerocket NodePool to the same cluster, you would label it `amiFamily: bottlerocket` and add `nvidia.com/gpu.deploy.device-plugin: "false"` so the device plugin DaemonSet skips those nodes (Bottlerocket already has it built in).

Verify the plugin is installed (zero pods until a GPU NodePool with the matching label is provisioned):

```bash
kubectl get daemonset nvidia-device-plugin -n kube-system
```

Expected output:

```
NAME                   DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR      AGE
nvidia-device-plugin   0         0         0       0            0           amiFamily=al2023   2m5s
```

`DESIRED 0` means no nodes currently match the `amiFamily=al2023` selector. The `gpu-inf` NodePool you create in the next section labels its nodes with `amiFamily: al2023`, so the DaemonSet will start scheduling pods as soon as Karpenter provisions the first GPU node.

## Create GPU NodePool and NodeClass

Karpenter uses an `EC2NodeClass` (the AWS-specific launch template equivalent) and a `NodePool` (the scheduling policy). Auto Mode bundles both into a single `NodeClass`/`NodePool` pair. Here you create them explicitly.

SOCI is pre-installed on the EKS-optimized AL2023 AMI (> v20250821), so enabling it only requires flipping the `FastImagePull` feature gate via `nodeadm` `NodeConfig` in `userData`. No binary downloads or systemd units required.

Create the EC2NodeClass:

```bash
cat << EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-inf
spec:
  role: "eksctl-KarpenterNodeRole-${CLUSTER_NAME}"
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  instanceStorePolicy: RAID0
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      featureGates:
        FastImagePull: true
      containerd:
        config: |
          [plugins."io.containerd.snapshotter.v1.soci"]
            [plugins."io.containerd.snapshotter.v1.soci".blob]
              max_concurrent_downloads_per_image = 20
              concurrent_download_chunk_size = "16mb"
              max_concurrent_unpacks_per_image = 12
              discard_unpacked_layers = true

    --BOUNDARY--
EOF
```

The `al2023@latest` AMI alias resolves to the EKS-optimized Amazon Linux 2023 AMI. When Karpenter launches a GPU instance type, it automatically selects the `AL2023_x86_64_NVIDIA` accelerated variant, which includes the NVIDIA driver pre-installed.

The `FastImagePull` feature gate enables SOCI snapshotter parallel pull/unpack mode, which downloads and unpacks image layers concurrently. This matches what Auto Mode does on G, P, and Trn instances. The `containerd.config` block tunes the SOCI snapshotter for ECR-hosted images:

- **`max_concurrent_downloads_per_image: 20`** allows up to 20 layer downloads in parallel per image. Default is 3 on Bottlerocket and 20 on AL2023. Recommended value for ECR.
- **`concurrent_download_chunk_size: "16mb"`** splits each layer into 16 MB chunks downloaded in parallel via HTTP range requests. Recommended for registries that support range GETs (ECR does).
- **`max_concurrent_unpacks_per_image: 12`** unpacks up to 12 layers at once. Default is 1 on Bottlerocket and 12 on AL2023.
- **`discard_unpacked_layers: true`** deletes compressed layer blobs after unpacking to save disk space.

Validate the EC2NodeClass was created:

```bash
kubectl get ec2nodeclass gpu-inf
```

Expected output:

```
NAME      READY   AGE
gpu-inf   True    10s
```

If `READY` is `False`, run `kubectl describe ec2nodeclass gpu-inf` and check the conditions for hints, usually a missing tag on subnets or security groups.

### A note on storage for SOCI

SOCI writes image layer blobs to disk while pulling, so the speed of the underlying disk directly affects pull time.

GPU instance families (G, P, Trn) come with local NVMe instance store disks attached to the host. These are significantly faster than EBS and are included in the instance price. `instanceStorePolicy: RAID0` tells Karpenter to assemble all available NVMe disks into a RAID-0 array and relocate `/var/lib/containerd`, `/var/lib/kubelet`, and `/var/log/pods` onto it. This moves the containerd image cache off the root EBS volume and onto the local NVMe, which is where the SOCI parallel mode speedup actually comes from on these families.

For instance types without local NVMe (most M, C, and R families), `instanceStorePolicy: RAID0` has no effect. In that case SOCI writes to the root EBS volume, which defaults to 20 GiB gp3 at 3000 IOPS and 125 MiB/s throughput. That default is fine for normal workloads but becomes the bottleneck when pulling a 10 GiB ML image. If you plan to run SOCI on non-NVMe instances, bump the root volume via `blockDeviceMappings` at the top level of the `EC2NodeClass.spec` (same level as `instanceStorePolicy` and `userData`):

```yaml
spec:
  # ... other fields ...
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
```

For more SOCI tuning options (concurrent downloads per image, chunk size, etc.), see the [Karpenter SOCI blueprint](https://github.com/aws-samples/karpenter-blueprints/tree/main/blueprints/soci-snapshotter).

Create the GPU NodePool:

```bash
cat << EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-inf
spec:
  template:
    metadata:
      labels:
        guide: eks-docs-inf
        amiFamily: al2023
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-inf
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g"]
        - key: karpenter.k8s.aws/instance-generation
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

The structure mirrors the Auto Mode equivalent in the [auto mode walkthrough](automode.md#create-gpu-nodepool-for-inference). The only differences are the label prefix (`karpenter.k8s.aws/` instead of `eks.amazonaws.com/`) and the `nodeClassRef` pointing at the `EC2NodeClass` you created above.

Validate the NodePool was created:

```bash
kubectl get nodepool gpu-inf
```

Expected output:

```
NAME      NODECLASS   NODES   READY   AGE
gpu-inf   gpu-inf     0       True    10s
```

The NodePool starts with zero nodes. Karpenter provisions GPU instances when a pod with matching tolerations and resource requests is scheduled.

## Test with a Sample Pod

Deploy the same `nvidia-smi` test pod used in the Auto Mode walkthrough:

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

Wait for the pod to complete. Karpenter will provision a GPU node, the NVIDIA device plugin will expose the GPU, and `nvidia-smi` will print device info:

```bash
kubectl get pods -w
```

Once `STATUS: Completed`, check the logs:

```bash
kubectl logs nvidia-smi
```

Expected output matches the Auto Mode walkthrough: a table with GPU model, driver version, CUDA version, and memory usage. The model depends on which G-family instance Karpenter selected.

Check that the node and NodeClaim came from your GPU NodePool:

```bash
kubectl get nodeclaims
```

Expected output:

```
NAME            TYPE          CAPACITY    ZONE         NODE                  READY   AGE
gpu-inf-xxxxx   g6e.xlarge    spot        us-east-2a   i-0xxxxxxxxxxxx       True    2m
```

## Attach an On-Demand Capacity Reservation (ODCR) (optional)

The same reserved-first pattern from the Auto Mode walkthrough applies here. See the [Auto Mode ODCR section](automode.md#attach-an-on-demand-capacity-reservation-odcr) for the full walkthrough. The only change is the NodeClass field: add `capacityReservationSelectorTerms` under `spec` on the `EC2NodeClass` (same field name, same shape as Auto Mode's `NodeClass`).

## Recovering from Karpenter Helm install failure

If `eksctl create cluster` failed at the Karpenter Helm step with a 403 error like `Your authorization token has expired`, the cluster, managed node group, IAM roles, SQS queue, and addons all came up successfully. Only the Karpenter Helm release is missing. You can finish the install yourself without recreating the cluster.

Re-authenticate Helm to public ECR:

```bash
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws
```

Look up the Karpenter controller IAM role that eksctl created:

```bash
KARPENTER_ROLE_ARN=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'KarpenterController') && contains(RoleName, '${CLUSTER_NAME}')].Arn | [0]" \
  --output text)
echo "Karpenter role: ${KARPENTER_ROLE_ARN}"
```

Install the Karpenter Helm chart pointing at the existing role and SQS queue:

```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace karpenter \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --wait
```

Verify the Karpenter pods are running:

```bash
kubectl get pods -n karpenter
```

Then continue with the [Enable Automatic Node Repair](#enable-automatic-node-repair) step.

## Cleanup

> **Note:** If you plan to continue with the next sections of this guide, skip the full cleanup. Only run it when you are done.

### Clean Up GPU Pods

If you are starting from a new terminal, set the cluster name and region:

```bash
export CLUSTER_NAME=eks-docs-inf
export AWS_REGION=us-east-2
```

Delete any test pods so GPU nodes can drain:

```bash
kubectl delete pod nvidia-smi --ignore-not-found
```

### Delete the Cluster

The cluster, managed node group, Karpenter installation, IAM roles, and VPC are all managed by the eksctl config. Delete them in one command:

```bash
eksctl delete cluster --name=$CLUSTER_NAME --region=$AWS_REGION
```

eksctl tears down Karpenter-provisioned nodes before deleting the control plane. This can take 10-15 minutes.

---

[← Back to main guide](../README.md) | [Next: Set up monitoring →](../monitoring.md)
