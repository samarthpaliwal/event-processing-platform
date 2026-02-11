#!/bin/bash
set -e

echo "Setting up Event Processing Platform..."

# Install dependencies
echo "Installing API dependencies..."
cd api
pip install -r requirements.txt
cd ..

echo "Installing Worker dependencies..."
cd worker
pip install -r requirements.txt
cd ..

# Setup AWS infrastructure
echo "Initializing Terraform..."
cd infrastructure/terraform
terraform init
echo "Terraform initialized. Run 'terraform plan' to review changes."
cd ../..

echo "Setup complete!"
echo ""
echo "Next steps:"
echo "1. Configure AWS credentials"
echo "2. Update terraform variables in infrastructure/terraform/variables.tf"
echo "3. Run 'terraform apply' in infrastructure/terraform/"
echo "4. Update GitHub secrets for CI/CD"
