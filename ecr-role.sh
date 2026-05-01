#!/bin/bash
set -e

ROLE_NAME="ImageUpdaterECRRole"
POLICY_NAME="ImageUpdaterECRPolicy"

echo "Checking AWS credentials..."
# Get the current account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT_ID" ]; then
    echo "Failed to get AWS Account ID. Please configure your AWS credentials first."
    echo "Run 'aws configure' or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
    exit 1
fi

echo "Current Account ID: $ACCOUNT_ID"
echo "Creating IAM Role: $ROLE_NAME..."

# Create trust policy document allowing anyone in the account to assume it
# (In a strict production environment, you might restrict this to a specific user)
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Check if role already exists
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role $ROLE_NAME already exists. Updating assumable trust policy..."
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document file://trust-policy.json
else
    # Create the role
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json > /dev/null
    echo "Role created successfully."
fi

echo "Creating and attaching policy: $POLICY_NAME..."

# Create ECR permissions policy document
cat > ecr-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:DescribeImages",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:*:${ACCOUNT_ID}:repository/*"
    }
  ]
}
EOF

# Attach the inline policy to the role
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document file://ecr-policy.json

echo "Policy attached successfully."

# Clean up
rm trust-policy.json ecr-policy.json

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "=================================================="
echo "Setup Complete!"
echo "Role ARN: $ROLE_ARN"
echo "Add this ARN to your updater.env file:"
echo "AWS_ROLE_ARN=$ROLE_ARN"
echo "=================================================="
