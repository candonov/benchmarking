# Inference Cluster Setup (CLI)

This guide walks through setting up an EKS cluster for GPU inference workloads using the AWS CLI and `eksctl`. It is organized into three topics that you can follow in order or complete independently depending on what you need.

## Folder Structure

```
cluster-setup/cli/
├── cluster-and-compute/    Cluster creation and GPU NodePool setup
│   ├── automode.md               EKS Auto Mode walkthrough
│   └── karpenter.md              Self-managed Karpenter walkthrough (placeholder)
├── monitoring.md           Prometheus, Grafana, and DCGM exporter
└── s3-model-loading.md     S3 bucket and Pod Identity for pod-side model downloads
```

## Sections

1. [**Set up cluster and compute**](cluster-and-compute/README.md). Choose between EKS Auto Mode (managed compute) or EKS with self-managed open source Karpenter, then create the cluster and a GPU NodePool that launches reserved capacity first and falls back to Spot or On-Demand.
2. [**Set up monitoring**](monitoring.md). Install kube-prometheus-stack with Amazon Managed Prometheus remote-write and DCGM exporter for GPU metrics.
3. [**Set up S3 model loading**](s3-model-loading.md). Create an S3 bucket for model weights and configure Pod Identity so pods can read from it directly using the AWS SDK or CLI.

Each section includes a **Cleanup** subsection you can run independently when you are done with that part of the guide.
