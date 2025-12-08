#!/usr/bin/env bash
set -euo pipefail

########################################
# EDIT THESE VALUES
########################################
CLUSTER_NAME="my-eks-cluster"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="111122223333"
LBC_VERSION="v2.14.1"
HELM_CHART_VERSION="1.14.0"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
########################################

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "=== Updating kubeconfig for cluster '$CLUSTER_NAME' in region '$AWS_REGION' ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

########################################
# 1. JUST CREATE OIDC PROVIDER (NO CHECK)
########################################
echo
echo "=== Creating IAM OIDC provider via eksctl (if not already present) ==="

# eksctl is idempotent here – if OIDC provider exists, it will just succeed.
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

########################################
# 2. IAM POLICY FOR ALB CONTROLLER
########################################
echo
echo "=== Checking IAM policy for AWS Load Balancer Controller ==="

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "IAM policy already exists: $POLICY_NAME"
else
  echo "IAM policy not found, downloading policy JSON from GitHub..."
  curl -sS -o iam_policy.json \
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

  echo "Creating IAM policy: $POLICY_NAME"
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file://iam_policy.json >/dev/null

  rm -f iam_policy.json
fi

########################################
# 3. IAM SERVICE ACCOUNT (IRSA)
########################################
echo
echo "=== Configuring IAM service account for AWS Load Balancer Controller ==="

eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --region "$AWS_REGION" \
  --approve

########################################
# 4. HELM INSTALL / UPGRADE
########################################
echo
echo "=== Installing / Upgrading AWS Load Balancer Controller via Helm ==="

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null 2>&1

if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "Helm release exists, upgrading..."
  helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --version "$HELM_CHART_VERSION"
else
  echo "Helm release not found, installing..."
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --version "$HELM_CHART_VERSION"
fi

########################################
# 5. VERIFY
########################################
echo
echo "=== Verification ==="
kubectl get deployment -n kube-system aws-load-balancer-controller

echo
echo "✅ AWS Load Balancer Controller installation complete."
