#!/bin/bash
set -e

DOCR_REGISTRY="registry.digitalocean.com"

echo "Checking DigitalOcean credentials..."
if ! command -v curl &>/dev/null; then
    echo "Failed: curl is not installed."
    exit 1
fi

echo ""
echo "Create a Personal Access Token with read scope at:"
echo "https://cloud.digitalocean.com/account/api/tokens"
echo ""

read -p "Enter DO Registry name (slug from DigitalOcean → Container Registry): " DO_REGISTRY
if [ -z "$DO_REGISTRY" ]; then
    echo "Registry name is required."
    exit 1
fi

read -sp "Enter Personal Access Token: " DO_TOKEN; echo ""
if [ -z "$DO_TOKEN" ]; then
    echo "Token is required."
    exit 1
fi

echo "Verifying token via DigitalOcean API..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $DO_TOKEN" \
    "https://api.digitalocean.com/v2/registry")

if [ "$HTTP_STATUS" == "200" ]; then
    echo "Token is valid and registry API is reachable."
elif [ "$HTTP_STATUS" == "401" ]; then
    echo "Token is invalid (HTTP 401). Check the token value and its read scope."
    exit 1
else
    echo "Unexpected HTTP $HTTP_STATUS from DigitalOcean API."
    exit 1
fi

echo "Verifying docker login to $DOCR_REGISTRY ..."
echo "$DO_TOKEN" | docker login "$DOCR_REGISTRY" \
    -u "$DO_TOKEN" --password-stdin >/dev/null 2>&1
echo "Login verified successfully."

echo "Policy attached successfully."

echo ""
echo "=================================================="
echo "Setup Complete!"
echo "Registry : $DOCR_REGISTRY/$DO_REGISTRY"
echo "Add these to your updater.env file:"
echo "DO_REGISTRY=$DO_REGISTRY"
echo "DO_TOKEN=$DO_TOKEN"
echo "=================================================="
