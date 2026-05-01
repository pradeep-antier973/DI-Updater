#!/bin/bash
set -e

SA_NAME="image-updater-sa"
SA_DISPLAY="ImageUpdater Service Account"

echo "Checking Google Cloud credentials..."
if ! command -v gcloud &>/dev/null; then
    echo "Failed: gcloud CLI is not installed."
    echo "Install it from https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Verify active session
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -z "$ACTIVE_ACCOUNT" ]; then
    echo "Not logged in. Running 'gcloud auth login'..."
    gcloud auth login --quiet
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
fi
echo "Active account: $ACTIVE_ACCOUNT"

GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -z "$GCP_PROJECT" ]; then
    read -p "Enter GCP Project ID: " GCP_PROJECT
fi
echo "Project: $GCP_PROJECT"

# Detect registry type
echo ""
echo "Registry type:"
echo "1) GCR  — gcr.io / us.gcr.io / eu.gcr.io / asia.gcr.io"
echo "2) AR   — Artifact Registry (*-docker.pkg.dev)"
read -p "Enter your choice [1-2]: " reg_choice

SA_EMAIL="${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"

echo "Creating Service Account: $SA_NAME ..."
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    echo "Service Account '$SA_NAME' already exists."
else
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name "$SA_DISPLAY" \
        --project "$GCP_PROJECT"
    echo "Service Account created successfully."
fi

echo "Attaching minimum read permissions..."
if [ "$reg_choice" == "2" ]; then
    # Artifact Registry reader role
    gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
        --member "serviceAccount:${SA_EMAIL}" \
        --role "roles/artifactregistry.reader" \
        --condition=None \
        --quiet
    GCP_REGISTRY_URL="us-docker.pkg.dev"
    echo "Granted: roles/artifactregistry.reader"
else
    # GCR uses Cloud Storage — objectViewer covers read access
    gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
        --member "serviceAccount:${SA_EMAIL}" \
        --role "roles/storage.objectViewer" \
        --condition=None \
        --quiet
    GCP_REGISTRY_URL="gcr.io"
    echo "Granted: roles/storage.objectViewer (GCR)"
fi

echo "Creating JSON key for Service Account..."
KEY_FILE="/tmp/gcp-image-updater-key.json"
gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account "$SA_EMAIL" \
    --project "$GCP_PROJECT"

GCP_SERVICE_ACCOUNT_JSON=$(cat "$KEY_FILE")
rm -f "$KEY_FILE"

echo "Policy attached successfully."

echo ""
echo "=================================================="
echo "Setup Complete!"
echo "Service Account: $SA_EMAIL"
echo "Add these to your updater.env file:"
echo "GCP_REGISTRY_URL=$GCP_REGISTRY_URL"
echo "GCP_PROJECT=$GCP_PROJECT"
echo "GCP_SERVICE_ACCOUNT_JSON=$(cat /dev/null)  # (written below — too long to display)"
echo "=================================================="
echo ""
echo "GCP_SERVICE_ACCOUNT_JSON key preview (first 80 chars):"
echo "${GCP_SERVICE_ACCOUNT_JSON:0:80}..."
echo ""
echo "Full JSON written below — copy and paste into updater.env:"
echo "GCP_SERVICE_ACCOUNT_JSON=${GCP_SERVICE_ACCOUNT_JSON}"
