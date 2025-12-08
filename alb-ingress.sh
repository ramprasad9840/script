
CLUSTER_NAME=<your-cluster-name>
REGION=<your-region>   # e.g. ap-south-1

OIDC_URL=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

echo "OIDC_URL = $OIDC_URL"

curl -I "$OIDC_URL"
