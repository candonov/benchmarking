# Set Up S3 Model Storage

If you are starting from this section or opened a new terminal, set the environment variables from the previous step:

```bash
# NOTE: Keep this cluster name consistent throughout the guide. Do not modify.
export CLUSTER_NAME=eks-docs-inf
export AWS_REGION=us-east-2
```

## Create S3 Bucket for Model Storage

Create an S3 bucket to store model weights. The bucket name includes a random suffix to avoid naming conflicts:

```bash
BUCKET_SUFFIX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
MODEL_BUCKET="${CLUSTER_NAME}-models-${BUCKET_SUFFIX}"

aws s3 mb s3://${MODEL_BUCKET} --region ${AWS_REGION}
```

Expected output:

```
make_bucket: eks-docs-inf-models-01234567
```

S3 buckets created after January 2023 have server-side encryption (AES256) and public access blocking enabled by default.

## Configure Pod Identity for S3 Access

Create a Kubernetes ServiceAccount and associate it with an IAM role that has access to the model bucket. This allows pods using the ServiceAccount to read and write model weights from S3.

Create the ServiceAccount:

```bash
kubectl create serviceaccount model-storage-sa
```

Expected output:

```
serviceaccount/model-storage-sa created
```

Create an IAM policy that grants access to the model bucket:

```bash
cat << EOF > /tmp/s3-model-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${MODEL_BUCKET}",
        "arn:aws:s3:::${MODEL_BUCKET}/*"
      ]
    }
  ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
  --policy-name "${CLUSTER_NAME}-model-storage-policy" \
  --policy-document file:///tmp/s3-model-policy.json \
  --query 'Policy.Arn' \
  --output text)

echo "Policy ARN: ${POLICY_ARN}"
```

Expected output:

```
Policy ARN: arn:aws:iam::123456789012:policy/eks-docs-inf-model-storage-policy
```

Create the Pod Identity Association using eksctl. This creates the IAM role with the correct trust policy and links it to the ServiceAccount:

```bash
eksctl create podidentityassociation \
  --cluster ${CLUSTER_NAME} \
  --namespace default \
  --service-account-name model-storage-sa \
  --role-name "${CLUSTER_NAME}-model-storage-role" \
  --permission-policy-arns ${POLICY_ARN} \
  --region ${AWS_REGION}
```

Verify the association:

```bash
eksctl get podidentityassociation --cluster ${CLUSTER_NAME} --region ${AWS_REGION}
```

Expected output:

```
ASSOCIATION ARN                                                                             NAMESPACE   SERVICE ACCOUNT NAME   IAM ROLE ARN
arn:aws:eks:us-east-2:123456789012:podidentityassociation/eks-docs-inf/a-xxxxxxxxxxxxxxxxx  default     model-storage-sa       arn:aws:iam::123456789012:role/eks-docs-inf-model-storage-role
```

Pods using `serviceAccountName: model-storage-sa` will now have access to the `${MODEL_BUCKET}` bucket.

### Validate S3 Access from a Pod

Run a pod with the AWS CLI using the `model-storage-sa` ServiceAccount to verify the pod identity is working and S3 access is configured correctly:

```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: s3-test
  labels:
    guide: eks-docs-inf
spec:
  serviceAccountName: model-storage-sa
  containers:
    - name: aws-cli
      image: public.ecr.aws/aws-cli/aws-cli:latest
      command:
        - sh
        - -c
        - |
          echo "=== Caller Identity ==="
          aws sts get-caller-identity
          echo ""
          echo "=== S3 Write Test ==="
          echo "pod identity works" | aws s3 cp - s3://${MODEL_BUCKET}/test.txt
          echo ""
          echo "=== S3 List Test ==="
          aws s3 ls s3://${MODEL_BUCKET}/
          echo ""
          echo "=== S3 Delete Test ==="
          aws s3 rm s3://${MODEL_BUCKET}/test.txt
  restartPolicy: Never
EOF
```

Wait for the pod to complete and check the logs:

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/s3-test --timeout=120s
kubectl logs s3-test
```

Expected output:

```
=== Caller Identity ===
{
    "UserId": "AROA...:eks-eks-docs-inf-model-s-...",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/eks-docs-inf-model-storage-role/eks-eks-docs-inf-model-s-..."
}

=== S3 Write Test ===
upload: - to s3://eks-docs-inf-models-01234567/test.txt

=== S3 List Test ===
2026-05-04 12:00:00         19 test.txt

=== S3 Delete Test ===
delete: s3://eks-docs-inf-models-01234567/test.txt
```

The caller identity confirms the pod assumed the `eks-docs-inf-model-storage-role` role via Pod Identity. The S3 commands confirm read and write access to the bucket.

Clean up the test pod:

```bash
kubectl delete pod s3-test
```

---

[← Previous: Set up cluster and nodes](01-cluster-and-nodes.md) | [Next: Set up monitoring →](03-monitoring.md)

---

## Cleanup

> **Note:** If you plan to continue to the next section, skip the cleanup. Only run it when you are done with the S3 model storage.

### Clean Up S3 Bucket and Pod Identity

If you are starting from a new terminal, set the cluster name and region:

```bash
export CLUSTER_NAME=eks-docs-inf
export AWS_REGION=us-east-2
```

Look up the model bucket name:

```bash
MODEL_BUCKET=$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, '${CLUSTER_NAME}-models-')].Name | [0]" \
  --output text)
echo "Model bucket: ${MODEL_BUCKET}"
```

Look up the IAM policy ARN:

```bash
POLICY_ARN=$(aws iam list-policies \
  --scope Local \
  --query "Policies[?PolicyName=='${CLUSTER_NAME}-model-storage-policy'].Arn" \
  --output text)
echo "Policy ARN: ${POLICY_ARN}"
```

Delete the S3 model bucket (including all objects):

```bash
aws s3 rb s3://${MODEL_BUCKET} --force
```

Delete the Pod Identity association for the S3 service account:

```bash
eksctl delete podidentityassociation \
  --cluster ${CLUSTER_NAME} \
  --namespace default \
  --service-account-name model-storage-sa \
  --region ${AWS_REGION}
```

Delete the IAM policy used for S3 access:

```bash
aws iam delete-policy --policy-arn ${POLICY_ARN}
```

Delete the Kubernetes ServiceAccount:

```bash
kubectl delete serviceaccount model-storage-sa
```

---

[← Previous: Cleanup Cluster and Nodes](01-cluster-and-nodes.md#cleanup) | [Next: Cleanup Monitoring →](03-monitoring.md#cleanup)
