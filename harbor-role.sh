#!/bin/bash
set -e

ROBOT_NAME="image-updater"

echo "Checking Harbor connectivity..."
if ! command -v curl &>/dev/null; then
    echo "Failed: curl is not installed."
    exit 1
fi

read -p "Enter Harbor URL (e.g. https://harbor.example.com): " HARBOR_URL
HARBOR_URL="${HARBOR_URL%/}"
if [ -z "$HARBOR_URL" ]; then
    echo "Harbor URL is required."
    exit 1
fi

# Ensure https:// prefix for API calls
if [[ ! "$HARBOR_URL" =~ ^https?:// ]]; then
    HARBOR_URL="https://${HARBOR_URL}"
fi
HARBOR_HOST=$(echo "$HARBOR_URL" | sed 's|https\?://||')

read -p "Enter Harbor admin username [admin]: " HARBOR_ADMIN_USER
HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
read -sp "Enter Harbor admin password: " HARBOR_ADMIN_PASS; echo ""

echo "Verifying Harbor credentials..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${HARBOR_ADMIN_USER}:${HARBOR_ADMIN_PASS}" \
    "${HARBOR_URL}/api/v2.0/ping")
if [ "$HTTP_STATUS" != "200" ]; then
    echo "Cannot reach Harbor API (HTTP $HTTP_STATUS). Check URL and admin credentials."
    exit 1
fi
echo "Harbor reachable. HTTP $HTTP_STATUS"

read -p "Enter project name to scope the robot account to (or leave blank for system-level): " HARBOR_PROJECT

echo "Creating Robot Account: robot\$${ROBOT_NAME} ..."

if [ -n "$HARBOR_PROJECT" ]; then
    # Project-scoped robot account
    ROBOT_PAYLOAD=$(cat <<EOF
{
  "name": "$ROBOT_NAME",
  "description": "Image Updater read-only robot",
  "duration": -1,
  "permissions": [
    {
      "kind": "project",
      "namespace": "$HARBOR_PROJECT",
      "access": [
        { "resource": "repository", "action": "pull" },
        { "resource": "artifact",   "action": "read" },
        { "resource": "tag",        "action": "list" }
      ]
    }
  ]
}
EOF
)
    SCOPE="project: $HARBOR_PROJECT"
else
    # System-level robot account
    ROBOT_PAYLOAD=$(cat <<EOF
{
  "name": "$ROBOT_NAME",
  "description": "Image Updater read-only robot",
  "duration": -1,
  "level": "system",
  "permissions": [
    {
      "kind": "project",
      "namespace": "*",
      "access": [
        { "resource": "repository", "action": "pull" },
        { "resource": "artifact",   "action": "read" },
        { "resource": "tag",        "action": "list" }
      ]
    }
  ]
}
EOF
)
    SCOPE="system-level (all projects)"
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -u "${HARBOR_ADMIN_USER}:${HARBOR_ADMIN_PASS}" \
    "${HARBOR_URL}/api/v2.0/robots" \
    -d "$ROBOT_PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" == "201" ]; then
    echo "Robot account created successfully."
elif [ "$HTTP_CODE" == "409" ]; then
    echo "Robot account already exists. Using existing account."
    echo "To reset the secret, delete and recreate the robot in Harbor UI."
    HARBOR_USERNAME="robot\$${ROBOT_NAME}"
    echo ""
    echo "=================================================="
    echo "Setup Complete!"
    echo "Registry : $HARBOR_HOST"
    echo "Scope    : $SCOPE"
    echo "Add these to your updater.env file:"
    echo "HARBOR_URL=$HARBOR_URL"
    echo "HARBOR_USERNAME=$HARBOR_USERNAME"
    echo "HARBOR_PASSWORD=<reset-secret-in-harbor-ui>"
    echo "=================================================="
    exit 0
else
    echo "Failed to create robot account (HTTP $HTTP_CODE)."
    echo "Response: $BODY"
    exit 1
fi

HARBOR_USERNAME=$(echo "$BODY" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
HARBOR_SECRET=$(echo "$BODY"   | grep -o '"secret":"[^"]*"' | cut -d'"' -f4)

echo "Policy attached successfully."

echo ""
echo "=================================================="
echo "Setup Complete!"
echo "Registry : $HARBOR_HOST"
echo "Scope    : $SCOPE"
echo "Add these to your updater.env file:"
echo "HARBOR_URL=$HARBOR_URL"
echo "HARBOR_USERNAME=robot\$${ROBOT_NAME}"
echo "HARBOR_PASSWORD=$HARBOR_SECRET"
echo "=================================================="
