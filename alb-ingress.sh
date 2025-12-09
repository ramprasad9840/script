#!/usr/bin/env bash
set -euo pipefail

# install-cwagent-eks.sh
# Installs CloudWatch Agent (Container Insights) on an EKS cluster (DaemonSet)
#
# Usage:
#   CLUSTER_NAME=my-eks-cluster REGION=ap-south-1 ./install-cwagent-eks.sh
#
# Optional: set USE_IRSA=true to create an IAM service account via eksctl (eksctl required)
#
# NOTE: This script applies upstream manifests. Review them if you need custom tuning.

: "${CLUSTER_NAME:=${CLUSTER_NAME:-}}"
: "${REGION:=${REGION:-}}"
NAMESPACE="${NAMESPACE:-amazon-cloudwatch}"
USE_IRSA="${USE_IRSA:-false}"   # set to "true" to use eksctl to create IRSA service account
SA_NAME="${SA_NAME:-cloudwatch-agent}"
TMPDIR="$(mktemp -d)"
CURL_OPTS="-sSL"

if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: CLUSTER_NAME environment variable must be set."
  echo "Example: CLUSTER_NAME=my-cluster REGION=ap-south-1 ./install-cwagent-eks.sh"
  exit 2
fi

echo "Installing CloudWatch Agent (Container Insights) to cluster: ${CLUSTER_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "IRSA via eksctl: ${USE_IRSA}"

# Prereqs quick check
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH"; exit 1; }
if [ "${USE_IRSA}" = "true" ]; then
  command -v eksctl >/dev/null 2>&1 || { echo "eksctl not found in PATH but USE_IRSA=true"; exit 1; }
fi

# Official upstream manifest locations (AWS samples / S3)
NS_URL="https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml"
SA_URL="https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-serviceaccount.yaml"
CONFIGMAP_URL="https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-configmap-enhanced.yaml"
DAEMONSET_URL="https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-daemonset.yaml"

echo "1) Creating namespace..."
kubectl apply -f "${NS_URL}"

echo "2) Creating RBAC / service account (clusterrole/clusterrolebinding included in manifest)..."
kubectl apply -f "${SA_URL}"

# Optionally create IRSA (eksctl create iamserviceaccount...) - recommended if you want IRSA
if [ "${USE_IRSA}" = "true" ]; then
  if [ -z "${REGION}" ]; then
    echo "REGION required when USE_IRSA=true"
    exit 2
  fi

  echo "3) Associating OIDC provider (if not already associated) and creating IAM service account via eksctl..."
  echo "   (may ask for approval to create IAM resources)"
  eksctl utils associate-iam-oidc-provider --cluster "${CLUSTER_NAME}" --region "${REGION}" --approve

  # create iam service account with AWS managed CloudWatch policy (CloudWatchAgentServerPolicy)
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --namespace "${NAMESPACE}" \
    --name "${SA_NAME}" \
    --attach-policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" \
    --override-existing-serviceaccounts \
    --approve
  echo "IRSA service account created/updated: ${NAMESPACE}/${SA_NAME}"
else
  echo "Skipping IRSA. Ensure node IAM role (instance profile) has permission to publish metrics/logs if not using IRSA."
fi

echo "4) Downloading CloudWatch agent ConfigMap and setting cluster_name -> ${CLUSTER_NAME}"
cd "${TMPDIR}"
curl ${CURL_OPTS} -o cwagent-configmap.yaml "${CONFIGMAP_URL}"

# replace "cluster_name": "" with actual cluster name (handles JSON/YAML style in configmap)
# safe sed that works on macOS and Linux
if sed --version >/dev/null 2>&1; then
  sed -i "s/\"cluster_name\": \"\"/\"cluster_name\": \"${CLUSTER_NAME}\"/g" cwagent-configmap.yaml
else
  # macOS sed
  sed -i '' "s/\"cluster_name\": \"\"/\"cluster_name\": \"${CLUSTER_NAME}\"/g" cwagent-configmap.yaml
fi

kubectl apply -f cwagent-configmap.yaml

echo "5) Deploying CloudWatch agent DaemonSet..."
kubectl apply -f "${DAEMONSET_URL}"

echo
echo "Verifications:"
echo "  kubectl -n ${NAMESPACE} get daemonset cloudwatch-agent"
echo "  kubectl -n ${NAMESPACE} get pods -l k8s-app=cloudwatch-agent"
echo
echo "You can tail logs of an agent pod to validate shipping:"
echo "  POD=\$(kubectl -n ${NAMESPACE} get pods -l k8s-app=cloudwatch-agent -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl -n ${NAMESPACE} logs -f \$POD -c cloudwatch-agent"
echo

echo "Cleanup: temporary files removed from ${TMPDIR}"
rm -rf "${TMPDIR}"

echo "Done. Container Insights CloudWatch Agent deployed. See CloudWatch Console (Container Insights) for metrics/logs."