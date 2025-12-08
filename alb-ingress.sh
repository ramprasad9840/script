#!/usr/bin/env bash
set -euo pipefail

########################################
# EDIT THESE VALUES
########################################
CLUSTER_NAME="my-eks-cluster"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="111122223333"
########################################

LBC_VERSION="v2.14.1"
HELM_CHART_VERSION="1.14.0"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "Updating kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

echo "Associating IAM OIDC provider for cluster ${CLUSTER_NAME}..."
eksctl utils associate-iam-oidc-provider \
  --cluster="$CLUSTER_NAME" \
  --region="$AWS_REGION" \
  --approve

echo "Downloading IAM policy document for AWS Load Balancer Controller..."
curl -sS -o iam_policy.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

echo "Creating IAM policy ${POLICY_NAME} (fails if it already exists)..."
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://iam_policy.json

echo "Creating IAM service account for AWS Load Balancer Controller..."
eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --region "$AWS_REGION" \
  --approve

echo "Installing AWS Load Balancer Controller via Helm..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null 2>&1

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --version "$HELM_CHART_VERSION"

echo "Verification:"
kubectl get deployment -n kube-system aws-load-balancer-controller

echo "AWS Load Balancer Controller installation complete."
