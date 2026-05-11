# Set up Cluster and Compute

This section sets up the EKS cluster and GPU NodePools that host inference workloads. Pick one of the two paths below based on how much of the compute lifecycle you want AWS to manage. Both produce an equivalent cluster and GPU NodePool for the rest of the guide.

- [**EKS Auto Mode**](automode.md) — AWS-managed compute with built-in Karpenter, node monitoring agent, and auto-repair. Recommended for most users.
- [**EKS with self-managed open source Karpenter**](karpenter.md) — run your own Karpenter controller on an EKS standard cluster. Useful when you need behavior beyond what Auto Mode exposes, such as custom Karpenter versions, additional controllers, or tight control over the node lifecycle.

---

[← Back to main guide](../README.md)
