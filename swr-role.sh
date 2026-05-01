#!/bin/bash
set -e

echo "Checking Huawei SWR credentials..."
if ! command -v curl &>/dev/null; then
    echo "Failed: curl is not installed."
    exit 1
fi
if ! command -v openssl &>/dev/null; then
    echo "Failed: openssl is not installed (required to derive login key from AK/SK)."
    exit 1
fi

echo ""
echo "Create AK/SK in Huawei Console → My Credentials → Access Keys"
echo "Docs: https://support.huaweicloud.com/intl/en-us/usermanual-iam/iam_02_0003.html"
echo ""

read -p "Enter SWR Region (e.g. cn-north-4): " SWR_REGION
if [ -z "$SWR_REGION" ]; then
    echo "SWR Region is required."
    exit 1
fi

read -p "Enter SWR Organisation (namespace): " SWR_ORGANIZATION
if [ -z "$SWR_ORGANIZATION" ]; then
    echo "SWR Organisation is required."
    exit 1
fi

read -p "Enter Access Key (AK): " SWR_ACCESS_KEY
read -sp "Enter Secret Key (SK): " SWR_SECRET_KEY; echo ""

if [ -z "$SWR_ACCESS_KEY" ] || [ -z "$SWR_SECRET_KEY" ]; then
    echo "AK and SK are both required."
    exit 1
fi

SWR_REGISTRY="swr.${SWR_REGION}.myhuaweicloud.com"

echo "Deriving login key from AK/SK (HMAC-SHA256)..."
DATETIME=$(date -u +"%Y%m%dT%H%M%SZ")
HEX=$(printf '%s' "$DATETIME" | openssl dgst -sha256 -hmac "$SWR_SECRET_KEY" | awk '{print $2}')
DERIVED_PASSWORD=$(printf '%s' "$HEX" | base64 -w0 2>/dev/null || printf '%s' "$HEX" | base64)
DERIVED_USERNAME="${SWR_REGION}@${SWR_ACCESS_KEY}"

echo "Verifying login to $SWR_REGISTRY ..."
LOGIN_OK=false
echo "$DERIVED_PASSWORD" | docker login "$SWR_REGISTRY" \
    -u "$DERIVED_USERNAME" --password-stdin >/dev/null 2>&1 \
    && LOGIN_OK=true

if $LOGIN_OK; then
    echo "Login verified successfully."
else
    echo "Login test failed — check AK/SK and that the account has SWR permissions."
    echo "Required IAM permissions: SWR ReadOnlyAccess (or SWR FullAccess)"
    exit 1
fi

echo "Policy attached successfully."

echo ""
echo "=================================================="
echo "Setup Complete!"
echo "Registry    : $SWR_REGISTRY"
echo "Organisation: $SWR_ORGANIZATION"
echo "Add these to your updater.env file:"
echo "SWR_REGION=$SWR_REGION"
echo "SWR_ORGANIZATION=$SWR_ORGANIZATION"
echo "SWR_ACCESS_KEY=$SWR_ACCESS_KEY"
echo "SWR_SECRET_KEY=$SWR_SECRET_KEY"
echo "=================================================="
