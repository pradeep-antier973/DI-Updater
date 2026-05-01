#!/bin/bash

# Configuration
ENV_FILE="$(dirname "$0")/.updater.env"
TEMP_FILE="/tmp/updater.env.tmp"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "[ERROR] jq is required but not installed."
    exit 1
fi

# =============================================================================
#  Interactive Registry Selection
# =============================================================================
echo ""
echo "========================================="
echo "  Select Cloud Provider & Container Registry"
echo "========================================="
echo "  1) AWS            - Amazon ECR"
echo "  2) Azure          - Azure Container Registry (ACR)"
echo "  3) GCP            - Google Container Registry (GCR / Artifact Registry)"
echo "  4) Docker Hub"
echo "  5) Harbor         - Harbor Registry"
echo "  6) Huawei Cloud   - SWR (Software Repository for Containers)"
echo "  7) DigitalOcean   - DO Container Registry (DOCR)"
echo "========================================="
read -p "  Enter your choice [1-7]: " choice
echo ""

case "$choice" in
    1) SELECTED_REGISTRY="ecr"       ;;
    2) SELECTED_REGISTRY="acr"       ;;
    3) SELECTED_REGISTRY="gcp"       ;;
    4) SELECTED_REGISTRY="dockerhub" ;;
    5) SELECTED_REGISTRY="harbor"    ;;
    6) SELECTED_REGISTRY="swr"       ;;
    7) SELECTED_REGISTRY="docr"      ;;
    *)
        echo "[ERROR] Invalid choice '$choice'. Please run the script again and select 1-7."
        exit 1
        ;;
esac

# ── Docker Hub: Public / Private / Both sub-menu ─────────────────────────────
DOCKERHUB_IMAGE_TYPE=""
if [ "$SELECTED_REGISTRY" == "dockerhub" ]; then
    echo "========================================="
    echo "  Docker Hub — Image Visibility"
    echo "========================================="
    echo "  1) Public   - No credentials needed"
    echo "  2) Private  - Requires username & password/token"
    echo "  3) Both     - Public + Private (credentials stored)"
    echo "========================================="
    read -p "  Enter your choice [1-3]: " dh_choice
    echo ""
    case "$dh_choice" in
        1) DOCKERHUB_IMAGE_TYPE="public"  ;;
        2) DOCKERHUB_IMAGE_TYPE="private" ;;
        3) DOCKERHUB_IMAGE_TYPE="both"    ;;
        *)
            echo "[ERROR] Invalid choice '$dh_choice'. Please run the script again and select 1-3."
            exit 1
            ;;
    esac
    log "Docker Hub image type: $DOCKERHUB_IMAGE_TYPE"
fi

log "Selected registry: $SELECTED_REGISTRY — starting container scan..."

# =============================================================================
# AWS / Amazon ECR Configuration (auto-detected from image URIs if present)
# =============================================================================
ACCOUNT_ID=""                    # AWS account ID (extracted from ECR image URIs)
REGION=""                        # AWS region (extracted from ECR image URIs)


# =============================================================================
# Docker Hub Configuration (auto-detected from image URIs if present)
# =============================================================================
DOCKERHUB_NAMESPACE_DETECTED=""  # Docker Hub namespace/username


# =============================================================================
# Harbor Registry Configuration (auto-detected from image URIs if present)
# =============================================================================
HARBOR_URL_DETECTED=""           # Harbor registry hostname (e.g. harbor.example.com)


# =============================================================================
# Azure Container Registry (ACR) Configuration (auto-detected)
# =============================================================================
AZURE_REGISTRY_DETECTED=""       # Azure ACR registry name (e.g. myregistry → myregistry.azurecr.io)


# =============================================================================
# Google Container Registry (GCR / Artifact Registry) Configuration (auto-detected)
# =============================================================================
GCP_REGISTRY_DETECTED=""         # GCP registry URL (e.g. gcr.io or us-docker.pkg.dev)
GCP_PROJECT_DETECTED=""          # GCP project ID


# =============================================================================
# Huawei SWR (SoftWare Repository) Configuration (auto-detected)
# =============================================================================
SWR_REGION_DETECTED=""           # Huawei SWR region code (e.g. cn-north-4)
SWR_ORG_DETECTED=""              # Huawei SWR organisation/namespace


# =============================================================================
# DigitalOcean Container Registry (DOCR) Configuration (auto-detected)
# =============================================================================
DOCR_REGISTRY_DETECTED=""        # DO registry name (e.g. myregistry → registry.digitalocean.com/myregistry)

# Associative arrays to store mappings per directory (requires Bash 4+)
declare -A REPO_MAPS
declare -A PATH_MAPS
declare -A DOCKERHUB_REPO_MAPS
declare -A HARBOR_REPO_MAPS
declare -A ACR_REPO_MAPS
declare -A GCP_REPO_MAPS
declare -A SWR_REPO_MAPS
declare -A DOCR_REPO_MAPS

CONTAINERS=$(docker ps -q)

for CID in $CONTAINERS; do
    INSPECT_JSON=$(docker inspect "$CID")

    # Extract Service Name (priority: label > config name)
    SERVICE=$(echo "$INSPECT_JSON" | jq -r '.[0].Config.Labels["com.docker.compose.service"]')
    if [ "$SERVICE" == "null" ] || [ -z "$SERVICE" ]; then
        SERVICE=$(echo "$INSPECT_JSON" | jq -r '.[0].Name' | sed 's/^\///')
    fi

    IMAGE=$(echo "$INSPECT_JSON" | jq -r '.[0].Config.Image')

    # Extract Full Config Files Path (Primary source of truth for Compose projects)
    CONFIG_FILES=$(echo "$INSPECT_JSON" | jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"]')

    # Skip container if it's not managed by Docker Compose (missing config_files label)
    if [ "$CONFIG_FILES" == "null" ] || [ -z "$CONFIG_FILES" ]; then
        continue
    fi

    # If multiple config files are present (comma-separated), take the first one
    PRIMARY_CONFIG=$(echo "$CONFIG_FILES" | cut -d',' -f1)

    # Derive directory suffix from the compose file (shared by all registry types)
    DIR_NAME=$(basename "$(dirname "$PRIMARY_CONFIG")" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    [ "$DIR_NAME" == "CUSTOM_IMAGE_UPDATER" ] && DIR_NAME="MAIN"

    if [ "$SELECTED_REGISTRY" == "ecr" ] && [[ $IMAGE =~ ([0-9]+)\.dkr\.ecr\.([^.]+)\.amazonaws\.com/([^:]+)(:.*)? ]]; then
        # ── AWS ECR ──────────────────────────────────────────────────────────
        ACC="${BASH_REMATCH[1]}"
        REG="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"

        log "ECR container detected: $SERVICE in $DIR_NAME ($REPO)"

        [ -z "$ACCOUNT_ID" ] && ACCOUNT_ID="$ACC"
        [ -z "$REGION" ]     && REGION="$REG"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${REPO_MAPS[$DIR_NAME]}" ]; then
            REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            REPO_MAPS[$DIR_NAME]="${REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "acr" ] && [[ $IMAGE =~ ^([a-zA-Z0-9-]+)\.azurecr\.io/([^/:]+)(:.*)? ]]; then
        # ── Azure ACR ({name}.azurecr.io) ────────────────────────────────────
        AZURE_REG="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"

        [ -z "$AZURE_REGISTRY_DETECTED" ] && AZURE_REGISTRY_DETECTED="$AZURE_REG"

        log "ACR container detected: $SERVICE in $DIR_NAME ($AZURE_REG/$REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${ACR_REPO_MAPS[$DIR_NAME]}" ]; then
            ACR_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${ACR_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            ACR_REPO_MAPS[$DIR_NAME]="${ACR_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "gcp" ] && [[ $IMAGE =~ ^([a-z0-9-]+-docker\.pkg\.dev)/([^/:]+)/([^/:]+)/([^/:]+)(:.*)? ]]; then
        # ── GCP Artifact Registry ({region}-docker.pkg.dev/{project}/{repo}/{image}) ─
        GCP_REG="${BASH_REMATCH[1]}"
        GCP_PROJ="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"   # repo/image

        [ -z "$GCP_REGISTRY_DETECTED" ] && GCP_REGISTRY_DETECTED="$GCP_REG"
        [ -z "$GCP_PROJECT_DETECTED"  ] && GCP_PROJECT_DETECTED="$GCP_PROJ"

        log "GCP AR container detected: $SERVICE in $DIR_NAME ($GCP_REG/$GCP_PROJ/$REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${GCP_REPO_MAPS[$DIR_NAME]}" ]; then
            GCP_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${GCP_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            GCP_REPO_MAPS[$DIR_NAME]="${GCP_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "gcp" ] && [[ $IMAGE =~ ^([a-z]*\.?gcr\.io)/([^/:]+)/([^/:]+)(:.*)? ]]; then
        # ── GCP Container Registry (gcr.io / {region}.gcr.io) ───────────────
        GCP_REG="${BASH_REMATCH[1]}"
        GCP_PROJ="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"

        [ -z "$GCP_REGISTRY_DETECTED" ] && GCP_REGISTRY_DETECTED="$GCP_REG"
        [ -z "$GCP_PROJECT_DETECTED"  ] && GCP_PROJECT_DETECTED="$GCP_PROJ"

        log "GCR container detected: $SERVICE in $DIR_NAME ($GCP_REG/$GCP_PROJ/$REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${GCP_REPO_MAPS[$DIR_NAME]}" ]; then
            GCP_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${GCP_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            GCP_REPO_MAPS[$DIR_NAME]="${GCP_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "swr" ] && [[ $IMAGE =~ ^swr\.([^.]+)\.myhuaweicloud\.com/([^/:]+)/([^/:]+)(:.*)? ]]; then
        # ── Huawei SWR ───────────────────────────────────────────────────────
        SWR_REG_REGION="${BASH_REMATCH[1]}"
        SWR_ORG_PART="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"

        [ -z "$SWR_REGION_DETECTED" ] && SWR_REGION_DETECTED="$SWR_REG_REGION"
        [ -z "$SWR_ORG_DETECTED"    ] && SWR_ORG_DETECTED="$SWR_ORG_PART"

        log "SWR container detected: $SERVICE in $DIR_NAME (swr.$SWR_REG_REGION/$SWR_ORG_PART/$REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${SWR_REPO_MAPS[$DIR_NAME]}" ]; then
            SWR_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${SWR_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            SWR_REPO_MAPS[$DIR_NAME]="${SWR_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "harbor" ] && [[ $IMAGE =~ ^([a-zA-Z0-9][a-zA-Z0-9._-]*\.[a-zA-Z]{2,})/(.+) ]] && \
         [[ ! $IMAGE =~ \.amazonaws\.com ]] && \
         [[ ! $IMAGE =~ (^docker\.io|/docker\.io) ]] && \
         [[ ! $IMAGE =~ \.azurecr\.io ]] && \
         [[ ! $IMAGE =~ (gcr\.io|pkg\.dev) ]] && \
         [[ ! $IMAGE =~ \.myhuaweicloud\.com ]]; then
        # ── Harbor (hostname with TLD, excluding all known cloud registries) ──
        HARBOR_HOST="${BASH_REMATCH[1]}"
        REST="${BASH_REMATCH[2]}"
        REPO=$(echo "$REST" | cut -d':' -f1)   # strip tag

        [ -z "$HARBOR_URL_DETECTED" ] && HARBOR_URL_DETECTED="$HARBOR_HOST"

        log "Harbor container detected: $SERVICE in $DIR_NAME ($HARBOR_HOST/$REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${HARBOR_REPO_MAPS[$DIR_NAME]}" ]; then
            HARBOR_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${HARBOR_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            HARBOR_REPO_MAPS[$DIR_NAME]="${HARBOR_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "dockerhub" ] && [[ $IMAGE =~ ^docker\.io/([^/:]+)/([^/:]+) ]]; then
        # ── Docker Hub (explicit docker.io prefix) ───────────────────────────
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        [ -z "$DOCKERHUB_NAMESPACE_DETECTED" ] && DOCKERHUB_NAMESPACE_DETECTED="${BASH_REMATCH[1]}"

        log "Docker Hub container detected: $SERVICE in $DIR_NAME ($REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${DOCKERHUB_REPO_MAPS[$DIR_NAME]}" ]; then
            DOCKERHUB_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${DOCKERHUB_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            DOCKERHUB_REPO_MAPS[$DIR_NAME]="${DOCKERHUB_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "dockerhub" ] && [[ $IMAGE =~ ^([^/.]+)/([^/:]+)(:.*)? ]]; then
        # ── Docker Hub (namespace/image, no registry host) ───────────────────
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        [ -z "$DOCKERHUB_NAMESPACE_DETECTED" ] && DOCKERHUB_NAMESPACE_DETECTED="${BASH_REMATCH[1]}"

        log "Docker Hub container detected: $SERVICE in $DIR_NAME ($REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${DOCKERHUB_REPO_MAPS[$DIR_NAME]}" ]; then
            DOCKERHUB_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${DOCKERHUB_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            DOCKERHUB_REPO_MAPS[$DIR_NAME]="${DOCKERHUB_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"

    elif [ "$SELECTED_REGISTRY" == "docr" ] && [[ $IMAGE =~ ^registry\.digitalocean\.com/([^/:]+)/([^/:]+)(:.*)? ]]; then
        # ── DigitalOcean Container Registry (registry.digitalocean.com/{registry}/{image}) ─
        DOCR_REG="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"

        [ -z "$DOCR_REGISTRY_DETECTED" ] && DOCR_REGISTRY_DETECTED="$DOCR_REG"

        log "DOCR container detected: $SERVICE in $DIR_NAME ($REPO)"

        MAPPING="$SERVICE=$REPO"
        if [ -z "${DOCR_REPO_MAPS[$DIR_NAME]}" ]; then
            DOCR_REPO_MAPS[$DIR_NAME]="$MAPPING"
        elif [[ ! "${DOCR_REPO_MAPS[$DIR_NAME]}" =~ "$SERVICE=" ]]; then
            DOCR_REPO_MAPS[$DIR_NAME]="${DOCR_REPO_MAPS[$DIR_NAME]},$MAPPING"
        fi
        PATH_MAPS[$DIR_NAME]="$PRIMARY_CONFIG"
    fi
done

log "Generating $ENV_FILE for registry: $SELECTED_REGISTRY ..."

# ── Capture existing credentials (preserve across re-runs) ───────────────────
# Check the environment file for existing values
get_val() {
    local key=$1
    local val=$(grep "^$key=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d'=' -f2-)
    echo "$val"
}

EXISTING_ADMIN_EMAIL=$(get_val "ADMIN_EMAIL")
EXISTING_ADMIN_PASS=$(get_val "ADMIN_PASSWORD")
EXISTING_U1_EMAIL=$(get_val "USER1_EMAIL")
EXISTING_U1_PASS=$(get_val "USER1_PASSWORD")
EXISTING_U2_EMAIL=$(get_val "USER2_EMAIL")
EXISTING_U2_PASS=$(get_val "USER2_PASSWORD")

EXISTING_DH_USERNAME=$(get_val "DOCKERHUB_USERNAME")
EXISTING_DH_PASSWORD=$(get_val "DOCKERHUB_PASSWORD")
EXISTING_DH_TOKEN=$(get_val "DOCKERHUB_TOKEN")

EXISTING_HARBOR_URL=$(get_val "HARBOR_URL")
EXISTING_HARBOR_USER=$(get_val "HARBOR_USERNAME")
EXISTING_HARBOR_PASS=$(get_val "HARBOR_PASSWORD")
[ -z "$EXISTING_HARBOR_URL" ] && EXISTING_HARBOR_URL="$HARBOR_URL_DETECTED"

EXISTING_AZURE_REGISTRY=$(get_val "AZURE_REGISTRY")
EXISTING_AZURE_USERNAME=$(get_val "AZURE_USERNAME")
EXISTING_AZURE_PASSWORD=$(get_val "AZURE_PASSWORD")
EXISTING_AZURE_TENANT=$(get_val "AZURE_TENANT_ID")
EXISTING_AZURE_CLIENT_ID=$(get_val "AZURE_CLIENT_ID")
EXISTING_AZURE_CLIENT_SECRET=$(get_val "AZURE_CLIENT_SECRET")
[ -z "$EXISTING_AZURE_REGISTRY" ] && EXISTING_AZURE_REGISTRY="$AZURE_REGISTRY_DETECTED"

EXISTING_GCP_REGISTRY=$(get_val "GCP_REGISTRY_URL")
EXISTING_GCP_PROJECT=$(get_val "GCP_PROJECT")
EXISTING_GCP_ACCESS_TOKEN=$(get_val "GCP_ACCESS_TOKEN")
[ -z "$EXISTING_GCP_REGISTRY" ] && EXISTING_GCP_REGISTRY="$GCP_REGISTRY_DETECTED"
[ -z "$EXISTING_GCP_PROJECT"  ] && EXISTING_GCP_PROJECT="$GCP_PROJECT_DETECTED"

EXISTING_SWR_REGION=$(get_val "SWR_REGION")
EXISTING_SWR_ORG=$(get_val "SWR_ORGANIZATION")
EXISTING_SWR_AK=$(get_val "SWR_ACCESS_KEY")
EXISTING_SWR_SK=$(get_val "SWR_SECRET_KEY")
EXISTING_SWR_USERNAME=$(get_val "SWR_USERNAME")
[ -z "$EXISTING_SWR_REGION" ] && EXISTING_SWR_REGION="$SWR_REGION_DETECTED"
[ -z "$EXISTING_SWR_ORG"    ] && EXISTING_SWR_ORG="$SWR_ORG_DETECTED"

EXISTING_DOCR_REGISTRY=$(get_val "DO_REGISTRY")
EXISTING_DOCR_TOKEN=$(get_val "DO_TOKEN")
[ -z "$EXISTING_DOCR_REGISTRY" ] && EXISTING_DOCR_REGISTRY="$DOCR_REGISTRY_DETECTED"

# Defaults if not found
[ -z "$EXISTING_ADMIN_EMAIL" ] && EXISTING_ADMIN_EMAIL="admin@example.com"
[ -z "$EXISTING_ADMIN_PASS"  ] && EXISTING_ADMIN_PASS="password123"
[ -z "$EXISTING_U1_EMAIL"    ] && EXISTING_U1_EMAIL="devops-shyam-atr1102"
[ -z "$EXISTING_U1_PASS"     ] && EXISTING_U1_PASS="admin@123"
[ -z "$EXISTING_U2_EMAIL"    ] && EXISTING_U2_EMAIL="devops-pradeep-atr973"
[ -z "$EXISTING_U2_PASS"     ] && EXISTING_U2_PASS="pradeep@2026"

# ── Write base section (common to all registries) ─────────────────────────────
cat <<EOF > "$TEMP_FILE"
# Admin user details
ADMIN_EMAIL=$EXISTING_ADMIN_EMAIL
ADMIN_PASSWORD=$EXISTING_ADMIN_PASS

# Additional Users (Managed via Environment Variables)
USER1_EMAIL=$EXISTING_U1_EMAIL
USER1_PASSWORD=$EXISTING_U1_PASS

USER2_EMAIL=$EXISTING_U2_EMAIL
USER2_PASSWORD=$EXISTING_U2_PASS

# Updater Configuration
CHECK_INTERVAL=30

# Global tag filter — applied to ALL services unless overridden per-service.
# Supports: Version, Build, Timestamp, Commit, Env, Pre-release, Latest, Branch, Release tags (Max length 25)
ALLOW_TAGS=regexp:^(v[0-9]+(\.[0-9]+){0,2}(-[a-z0-9]+)?|B[0-9]+|[0-9]{4}(-[0-9]{2}){5}|[a-z0-9]{7,15}|test-[a-z0-9-]+|prod|dev|qa|uat|stage|staging|latest|develop|(rel|release|stage|prod|dev|qa|uat)-v?[0-9]+(\.[0-9]+){0,2}(-[a-z0-9]+)?)$
# Define paths to docker-compose.yml files you want to manage.
EOF

echo "" >> "$TEMP_FILE"
for DIR in "${!PATH_MAPS[@]}"; do
    echo "COMPOSE_FILE_PATH_$DIR=${PATH_MAPS[$DIR]}" >> "$TEMP_FILE"
done

# ── Write registry-specific section based on user selection ───────────────────
case "$SELECTED_REGISTRY" in

    # ── 1) AWS ECR ────────────────────────────────────────────────────────────
    ecr)
        cat <<EOF >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# AWS / Amazon ECR Configuration (uncomment and fill in to enable ECR support)
# =============================================================================
# =============================================================================
# AWS_ACCESS_KEY_ID=<access_key>
# AWS_SECRET_ACCESS_KEY=<secret_key>

# Optional: IAM Role ARN to assume (e.g., cross-account or least privilege)
#AWS_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/ImageUpdaterECRRole

AWS_ACCOUNT_ID=$ACCOUNT_ID
AWS_REGION=$REGION
ECR_REGISTRY=\$AWS_ACCOUNT_ID.dkr.ecr.\$AWS_REGION.amazonaws.com

# Explicit mapping for your repos (if you don't use auto-discovery).
# Per-service tag filter syntax: service=repo:filter (overrides the global ALLOW_TAGS)
EOF
        for DIR in "${!REPO_MAPS[@]}"; do
            echo "ECR_REPOSITORY_MAP_$DIR=${REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
        done
        if [ ${#REPO_MAPS[@]} -eq 0 ]; then
            echo "# ECR_REPOSITORY_MAP_BACKEND=backend_web_nginx=my-ecr-repo" >> "$TEMP_FILE"
        fi
        ;;

    # ── 2) Azure ACR ──────────────────────────────────────────────────────────
    acr)
        cat <<'EOF' >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# Microsoft Azure Container Registry (ACR) — uncomment and fill in to enable ACR support
# =============================================================================
# =============================================================================
# Auth option A — Admin credentials (enable admin user in ACR → Access keys):
#   AZURE_REGISTRY=myregistry             # Registry name only; .azurecr.io is appended automatically
#   AZURE_USERNAME=myregistry             # Admin username shown in Access keys blade
#   AZURE_PASSWORD=<password>
#
# Auth option B — Service Principal (RBAC / AcrPull role):
#   AZURE_REGISTRY=myregistry
#   AZURE_TENANT_ID=<tenant-uuid>         # Setting this enables SP mode
#   AZURE_CLIENT_ID=<sp-app-id>           # Also accepted as AZURE_USERNAME
#   AZURE_CLIENT_SECRET=<sp-secret>       # Also accepted as AZURE_PASSWORD
#
# Map services to ACR repositories.
# Format: service=repo[:tag-filter]
EOF
        if [ -n "$EXISTING_AZURE_REGISTRY" ]; then
            echo "AZURE_REGISTRY=$EXISTING_AZURE_REGISTRY" >> "$TEMP_FILE"
        else
            echo "# AZURE_REGISTRY=myregistry" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_AZURE_TENANT" ]; then
            echo "AZURE_TENANT_ID=$EXISTING_AZURE_TENANT" >> "$TEMP_FILE"
            [ -n "$EXISTING_AZURE_CLIENT_ID"     ] && echo "AZURE_CLIENT_ID=$EXISTING_AZURE_CLIENT_ID"         >> "$TEMP_FILE" || echo "# AZURE_CLIENT_ID=<sp-app-id>"     >> "$TEMP_FILE"
            [ -n "$EXISTING_AZURE_CLIENT_SECRET" ] && echo "AZURE_CLIENT_SECRET=$EXISTING_AZURE_CLIENT_SECRET" >> "$TEMP_FILE" || echo "# AZURE_CLIENT_SECRET=<sp-secret>" >> "$TEMP_FILE"
        else
            echo "# AZURE_TENANT_ID=<tenant-uuid>   # Set this to enable Service Principal auth" >> "$TEMP_FILE"
            [ -n "$EXISTING_AZURE_USERNAME" ] && echo "AZURE_USERNAME=$EXISTING_AZURE_USERNAME" >> "$TEMP_FILE" || echo "# AZURE_USERNAME=<admin-user>" >> "$TEMP_FILE"
            [ -n "$EXISTING_AZURE_PASSWORD" ] && echo "AZURE_PASSWORD=$EXISTING_AZURE_PASSWORD" >> "$TEMP_FILE" || echo "# AZURE_PASSWORD=<admin-pass>" >> "$TEMP_FILE"
        fi
        if [ ${#ACR_REPO_MAPS[@]} -gt 0 ]; then
            echo "" >> "$TEMP_FILE"
            echo "# Auto-detected ACR service mappings:" >> "$TEMP_FILE"
            for DIR in "${!ACR_REPO_MAPS[@]}"; do
                echo "AZURE_REPOSITORY_MAP_$DIR=${ACR_REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
            done
        else
            echo "# AZURE_REPOSITORY_MAP_1=api_svc=my-api:v*" >> "$TEMP_FILE"
        fi
        ;;

    # ── 3) GCP ────────────────────────────────────────────────────────────────
    gcp)
        cat <<'EOF' >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# Google Cloud — GCR / Artifact Registry (uncomment and fill in to enable GCP support)
# =============================================================================
# =============================================================================
# GCP_REGISTRY_URL=gcr.io               # or us-docker.pkg.dev / eu-docker.pkg.dev etc.
# GCP_PROJECT=my-gcp-project            # Project ID — prepended to repo when no slash in repo name
#
# Auth option A — pre-generated access token (short-lived, rotate via cron):
#   GCP_ACCESS_TOKEN=ya29.xxxxxxxxxxxx
#
# Auth option B — Service Account JSON key (long-term, full RBAC control):
#   GCP_SERVICE_ACCOUNT_JSON={"type":"service_account","project_id":"...","private_key_id":"...",...}
#
# Map services to GCP repositories.
# Format: service=image[:tag-filter]  (project is prepended automatically from GCP_PROJECT)
EOF
        if [ -n "$EXISTING_GCP_REGISTRY" ]; then
            echo "GCP_REGISTRY_URL=$EXISTING_GCP_REGISTRY" >> "$TEMP_FILE"
        else
            echo "# GCP_REGISTRY_URL=gcr.io" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_GCP_PROJECT" ]; then
            echo "GCP_PROJECT=$EXISTING_GCP_PROJECT" >> "$TEMP_FILE"
        else
            echo "# GCP_PROJECT=my-gcp-project" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_GCP_ACCESS_TOKEN" ]; then
            echo "GCP_ACCESS_TOKEN=$EXISTING_GCP_ACCESS_TOKEN" >> "$TEMP_FILE"
        else
            echo "# GCP_ACCESS_TOKEN=ya29.xxx                  # Short-lived; rotate via cron" >> "$TEMP_FILE"
            echo "# GCP_SERVICE_ACCOUNT_JSON={...}             # Full JSON key for long-term SA auth" >> "$TEMP_FILE"
        fi
        if [ ${#GCP_REPO_MAPS[@]} -gt 0 ]; then
            echo "" >> "$TEMP_FILE"
            echo "# Auto-detected GCP service mappings:" >> "$TEMP_FILE"
            for DIR in "${!GCP_REPO_MAPS[@]}"; do
                echo "GCP_REPOSITORY_MAP_$DIR=${GCP_REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
            done
        else
            echo "# GCP_REPOSITORY_MAP_1=web_svc=my-image:v*" >> "$TEMP_FILE"
        fi
        ;;

    # ── 4) Docker Hub ─────────────────────────────────────────────────────────
    dockerhub)
        # Write header
        cat <<EOF >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# Docker Hub Configuration — Image Type: $DOCKERHUB_IMAGE_TYPE
# =============================================================================
# =============================================================================
EOF

        # ── Credentials block (skipped for public-only) ────────────────────────
        if [ "$DOCKERHUB_IMAGE_TYPE" == "public" ]; then
            cat <<'EOF' >> "$TEMP_FILE"
# Public images only — no credentials required.
# To pull private images in the future, add DOCKERHUB_USERNAME and
# DOCKERHUB_PASSWORD or DOCKERHUB_TOKEN below.
EOF
        else
            # private or both
            cat <<'EOF' >> "$TEMP_FILE"
# DOCKERHUB_USERNAME=myuser
# DOCKERHUB_PASSWORD=mypassword           # Use either password or personal access token
# DOCKERHUB_TOKEN=my-access-token         # Alternative to DOCKERHUB_PASSWORD (recommended)
#
# Map services to Docker Hub images.
# Format: service=namespace/image[:tag-filter]
EOF
            if [ -n "$EXISTING_DH_USERNAME" ]; then
                echo "DOCKERHUB_USERNAME=$EXISTING_DH_USERNAME" >> "$TEMP_FILE"
            else
                echo "# DOCKERHUB_USERNAME=myuser" >> "$TEMP_FILE"
            fi
            if [ -n "$EXISTING_DH_PASSWORD" ]; then
                echo "DOCKERHUB_PASSWORD=$EXISTING_DH_PASSWORD" >> "$TEMP_FILE"
            elif [ -n "$EXISTING_DH_TOKEN" ]; then
                echo "DOCKERHUB_TOKEN=$EXISTING_DH_TOKEN" >> "$TEMP_FILE"
            else
                echo "# DOCKERHUB_PASSWORD=mypassword" >> "$TEMP_FILE"
                echo "# DOCKERHUB_TOKEN=my-access-token" >> "$TEMP_FILE"
            fi
        fi

        # ── Image type flag written to env ─────────────────────────────────────
        echo "" >> "$TEMP_FILE"
        echo "# Docker Hub image visibility (public / private / both)" >> "$TEMP_FILE"
        echo "DOCKERHUB_IMAGE_TYPE=$DOCKERHUB_IMAGE_TYPE" >> "$TEMP_FILE"

        # ── Repository mappings ────────────────────────────────────────────────
        if [ ${#DOCKERHUB_REPO_MAPS[@]} -gt 0 ]; then
            echo "" >> "$TEMP_FILE"
            echo "# Auto-detected Docker Hub service mappings:" >> "$TEMP_FILE"
            for DIR in "${!DOCKERHUB_REPO_MAPS[@]}"; do
                echo "DOCKERHUB_REPOSITORY_MAP_$DIR=${DOCKERHUB_REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
            done
        else
            echo "# DOCKERHUB_REPOSITORY_MAP_1=web_nginx=myuser/myapp:v*" >> "$TEMP_FILE"
        fi
        ;;

    # ── 5) Harbor ─────────────────────────────────────────────────────────────
    harbor)
        cat <<'EOF' >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# Harbor Configuration (uncomment and fill in to enable Harbor registry support)
# =============================================================================
# =============================================================================
# HARBOR_URL=harbor.example.com           # With or without https:// prefix
# HARBOR_USERNAME=robot$myrobot           # Robot account recommended for automation
# HARBOR_PASSWORD=mysecret
#
# Map services to Harbor images.
# Format: service=project/image[:tag-filter]
EOF
        if [ -n "$EXISTING_HARBOR_URL" ]; then
            echo "HARBOR_URL=$EXISTING_HARBOR_URL" >> "$TEMP_FILE"
        else
            echo "# HARBOR_URL=harbor.example.com" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_HARBOR_USER" ]; then
            echo "HARBOR_USERNAME=$EXISTING_HARBOR_USER" >> "$TEMP_FILE"
        else
            echo "# HARBOR_USERNAME=robot\$myrobot" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_HARBOR_PASS" ]; then
            echo "HARBOR_PASSWORD=$EXISTING_HARBOR_PASS" >> "$TEMP_FILE"
        else
            echo "# HARBOR_PASSWORD=mysecret" >> "$TEMP_FILE"
        fi
        if [ ${#HARBOR_REPO_MAPS[@]} -gt 0 ]; then
            echo "" >> "$TEMP_FILE"
            echo "# Auto-detected Harbor service mappings:" >> "$TEMP_FILE"
            for DIR in "${!HARBOR_REPO_MAPS[@]}"; do
                echo "HARBOR_REPOSITORY_MAP_$DIR=${HARBOR_REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
            done
        else
            echo "# HARBOR_REPOSITORY_MAP_1=api_svc=myproject/api:v*" >> "$TEMP_FILE"
        fi
        ;;

    # ── 6) Huawei SWR ─────────────────────────────────────────────────────────
    swr)
        cat <<'EOF' >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# Huawei Cloud — Software Repository for Containers (SWR) — uncomment to enable SWR support
# =============================================================================
# =============================================================================
# SWR_REGION=cn-north-4                  # Region code; registry URL is derived automatically
# SWR_ORGANIZATION=my-org                # Namespace/organisation in SWR
#
# Auth option A — AK/SK (RBAC, login key generated via HMAC-SHA256 per session):
#   SWR_ACCESS_KEY=<AccessKey>
#   SWR_SECRET_KEY=<SecretKey>
#
# Auth option B — pre-generated long-term login key (from Huawei console):
#   SWR_USERNAME=cn-north-4@<AccessKey>
#   SWR_LOGIN_KEY=<base64-login-key>
#
# Map services to SWR repositories.
# Format: service=repo[:tag-filter]  (organisation is prepended automatically from SWR_ORGANIZATION)
EOF
        if [ -n "$EXISTING_SWR_REGION" ]; then
            echo "SWR_REGION=$EXISTING_SWR_REGION" >> "$TEMP_FILE"
        else
            echo "# SWR_REGION=cn-north-4" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_SWR_ORG" ]; then
            echo "SWR_ORGANIZATION=$EXISTING_SWR_ORG" >> "$TEMP_FILE"
        else
            echo "# SWR_ORGANIZATION=my-org" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_SWR_AK" ] && [ -n "$EXISTING_SWR_SK" ]; then
            echo "SWR_ACCESS_KEY=$EXISTING_SWR_AK" >> "$TEMP_FILE"
            echo "SWR_SECRET_KEY=$EXISTING_SWR_SK" >> "$TEMP_FILE"
        elif [ -n "$EXISTING_SWR_USERNAME" ]; then
            echo "SWR_USERNAME=$EXISTING_SWR_USERNAME" >> "$TEMP_FILE"
            echo "# SWR_LOGIN_KEY=<base64-key>"        >> "$TEMP_FILE"
        else
            echo "# SWR_ACCESS_KEY=<AccessKey>             # Preferred: login key derived automatically" >> "$TEMP_FILE"
            echo "# SWR_SECRET_KEY=<SecretKey>"            >> "$TEMP_FILE"
            echo "# -- OR pre-generated long-term key --"  >> "$TEMP_FILE"
            echo "# SWR_USERNAME=cn-north-4@<AccessKey>"   >> "$TEMP_FILE"
            echo "# SWR_LOGIN_KEY=<base64-login-key>"      >> "$TEMP_FILE"
        fi
        if [ ${#SWR_REPO_MAPS[@]} -gt 0 ]; then
            echo "" >> "$TEMP_FILE"
            echo "# Auto-detected SWR service mappings:" >> "$TEMP_FILE"
            for DIR in "${!SWR_REPO_MAPS[@]}"; do
                echo "SWR_REPOSITORY_MAP_$DIR=${SWR_REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
            done
        else
            echo "# SWR_REPOSITORY_MAP_1=api_svc=my-api:v*" >> "$TEMP_FILE"
        fi
        ;;

    # ── 7) DigitalOcean Container Registry (DOCR) ─────────────────────────────
    docr)
        cat <<'EOF' >> "$TEMP_FILE"

# =============================================================================
# =============================================================================
# DigitalOcean Container Registry (DOCR) — uncomment and fill in to enable DOCR support
# =============================================================================
# =============================================================================
# Registry URL format: registry.digitalocean.com/<registry-name>/<image>:<tag>
#
# Auth — Personal Access Token (used as both username and password):
#   DO_TOKEN=<your-digitalocean-personal-access-token>
#   DO_REGISTRY=myregistry                # Your DOCR registry name (slug)
#
# Map services to DOCR repositories.
# Format: service=registry-name/image[:tag-filter]
EOF
        if [ -n "$EXISTING_DOCR_REGISTRY" ]; then
            echo "DO_REGISTRY=$EXISTING_DOCR_REGISTRY" >> "$TEMP_FILE"
        else
            echo "# DO_REGISTRY=myregistry               # Registry name slug from DigitalOcean" >> "$TEMP_FILE"
        fi
        if [ -n "$EXISTING_DOCR_TOKEN" ]; then
            echo "DO_TOKEN=$EXISTING_DOCR_TOKEN" >> "$TEMP_FILE"
        else
            echo "# DO_TOKEN=<personal-access-token>     # From DigitalOcean → API → Tokens" >> "$TEMP_FILE"
        fi
        if [ ${#DOCR_REPO_MAPS[@]} -gt 0 ]; then
            echo "" >> "$TEMP_FILE"
            echo "# Auto-detected DOCR service mappings:" >> "$TEMP_FILE"
            for DIR in "${!DOCR_REPO_MAPS[@]}"; do
                echo "DO_REPOSITORY_MAP_$DIR=${DOCR_REPO_MAPS[$DIR]}" >> "$TEMP_FILE"
            done
        else
            echo "# DO_REPOSITORY_MAP_1=web_svc=myregistry/myapp:v*" >> "$TEMP_FILE"
        fi
        ;;
esac

mv "$TEMP_FILE" "$ENV_FILE"
log "Done. $ENV_FILE updated for registry: $SELECTED_REGISTRY"
