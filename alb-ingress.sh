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
# 1. OIDC PROVIDER SETUP (IDEMPOTENT)
########################################
echo
echo "=== Checking IAM OIDC provider ==="

# Get raw OIDC issuer URL from EKS
OIDC_URL_RAW=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

# Clean CR/LF and quotes
OIDC_URL=$(echo "$OIDC_URL_RAW" | tr -d '\r\n"')

if [[ -z "$OIDC_URL" || "$OIDC_URL" == "None" || "$OIDC_URL" == "null" ]]; then
  echo "ERROR: Cluster did not return a valid OIDC URL. Check CLUSTER_NAME / AWS_REGION."
  exit 1
fi

echo "OIDC URL   : $OIDC_URL"

# Extract final ID from URL: https://oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>
OIDC_ID=$(echo "$OIDC_URL" | awk -F/ '{print $NF}')

# Check if provider already exists in IAM
EXISTING_PROVIDER_ARN=$(
  aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_ID')].Arn" \
    --output text 2>/dev/null || true
)

if [[ -n "$EXISTING_PROVIDER_ARN" && "$EXISTING_PROVIDER_ARN" != "None" ]]; then
  echo "OIDC provider already exists:"
  echo "  $EXISTING_PROVIDER_ARN"
else
  echo "Creating IAM OIDC provider via eksctl..."
  eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --approve
fi

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
