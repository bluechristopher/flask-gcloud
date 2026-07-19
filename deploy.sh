#!/bin/bash
set -e

# Reset text formatting
NC='\033[0m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'

echo -e "${CYAN}${BOLD}====================================================${NC}"
echo -e "${CYAN}${BOLD}     Flask GCloud App Deployment Script             ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}"

echo -e "${YELLOW}Fetching your active Google Cloud projects...${NC}"
gcloud projects list --format="table(projectId,name)"
echo -e ""

# Detect current project ID
DEFAULT_PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
DEFAULT_PROJECT_ID=${DEFAULT_PROJECT_ID:-"flask-gcloud-502908"}

echo -e "Press [Enter] to use defaults shown in brackets."
echo -e ""

# 1. Prompt for Project ID
if [ -n "$DEFAULT_PROJECT_ID" ]; then
    read -p "Enter the Google Cloud Project ID from the list above [$DEFAULT_PROJECT_ID]: " PROJECT_ID
    PROJECT_ID=${PROJECT_ID:-$DEFAULT_PROJECT_ID}
else
    read -p "Enter the Google Cloud Project ID from the list above: " PROJECT_ID
    if [ -z "$PROJECT_ID" ]; then
        echo -e "${RED}Error: Project ID is required.${NC}"
        exit 1
    fi
fi

# Set project context
echo -e "Setting active project to ${GREEN}$PROJECT_ID${NC}..."
gcloud config set project "$PROJECT_ID"

# Get Project Number
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# 2. Prompt for Region
DEFAULT_REGION="asia-southeast1"
read -p "Enter GCP Region [$DEFAULT_REGION]: " REGION
REGION=${REGION:-$DEFAULT_REGION}

# 3. Prompt for Bucket Name
DEFAULT_BUCKET="db-flask-502908"
read -p "Enter GCS Bucket Name for SQLite DB [$DEFAULT_BUCKET]: " BUCKET_NAME
BUCKET_NAME=${BUCKET_NAME:-$DEFAULT_BUCKET}

# Define repository and service names
REPO_NAME="flask-gcloud-repo"
SERVICE_NAME="flask-gcloud-service"

echo -e "\n${CYAN}Configuration Summary:${NC}"
echo -e "  - Project ID:    ${GREEN}$PROJECT_ID${NC}"
echo -e "  - Project No:    ${GREEN}$PROJECT_NUMBER${NC}"
echo -e "  - Region:        ${GREEN}$REGION${NC}"
echo -e "  - GCS Bucket:    ${GREEN}$BUCKET_NAME${NC}"
echo -e "  - Artifact Repo: ${GREEN}$REPO_NAME${NC}"
echo -e "  - Cloud Run:     ${GREEN}$SERVICE_NAME${NC}"
echo -e ""

read -p "Proceed with deployment? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-"y"}
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${YELLOW}Deployment cancelled.${NC}"
    exit 0
fi

# Enable required APIs
echo -e "\n${CYAN}Enabling required Google Cloud APIs...${NC}"
gcloud services enable \
    run.googleapis.com \
    storage.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com

# Create GCS Bucket if it doesn't exist
echo -e "\n${CYAN}Checking GCS Bucket: gs://${BUCKET_NAME}...${NC}"
if gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
    echo -e "${GREEN}Bucket already exists.${NC}"
else
    echo -e "Creating GCS Bucket in region ${REGION}..."
    gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$REGION"
fi

# Grant Cloud Run Service Account permission to the GCS Bucket
# Cloud Run by default uses the default Compute Engine service account: PROJECT_NUMBER-compute@developer.gserviceaccount.com
RUN_SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo -e "\n${CYAN}Granting Storage Object Admin permission to Cloud Run service account (${RUN_SERVICE_ACCOUNT})...${NC}"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${RUN_SERVICE_ACCOUNT}" \
    --role="roles/storage.objectAdmin"

# Create Artifact Registry Repository if it doesn't exist
echo -e "\n${CYAN}Checking Artifact Registry: ${REPO_NAME} in ${REGION}...${NC}"
if gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" &>/dev/null; then
    echo -e "${GREEN}Artifact Registry repository already exists.${NC}"
else
    echo -e "Creating Artifact Registry repository..."
    gcloud artifacts repositories create "$REPO_NAME" \
        --repository-format=docker \
        --location="$REGION" \
        --description="Docker repository for Flask application"
fi

# Run the first build and deploy manually via Cloud Build
echo -e "\n${CYAN}Submitting manual build and deploy to Cloud Build...${NC}"
gcloud builds submit --config=cloudbuild.yaml \
    --substitutions="_LOCATION=${REGION},_REPO_NAME=${REPO_NAME},_SERVICE_NAME=${SERVICE_NAME},_BUCKET_NAME=${BUCKET_NAME}"

# Explicitly set the Cloud Run service to allow public access
echo -e "\n${CYAN}Setting Cloud Run service to allow public access...${NC}"
gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
    --region="$REGION" \
    --member="allUsers" \
    --role="roles/run.invoker" \
    --quiet

# Fetch service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --format="value(status.url)")

echo -e "\n${GREEN}${BOLD}====================================================${NC}"
echo -e "${GREEN}${BOLD}     Deployment Successful!                         ${NC}"
echo -e "${GREEN}${BOLD}====================================================${NC}"
echo -e "Your web application is now active at:"
echo -e "👉 ${CYAN}${BOLD}${SERVICE_URL}${NC}"
echo -e ""
echo -e "${YELLOW}${BOLD}Next Step: Setting up GitHub Auto-Update (CI/CD)${NC}"
echo -e "To make the application update automatically when your repo changes:"
echo -e "1. Go to the Cloud Build Console Triggers page:"
echo -e "   https://console.cloud.google.com/cloud-build/triggers?project=${PROJECT_ID}"
echo -e "2. Click ${BOLD}'Manage Repositories'${NC} and then ${BOLD}'Connect Repository'${NC}."
echo -e "3. Select 'GitHub (Cloud Build GitHub App)' and authorize connection to your repo: ${CYAN}bluechristopher/flask-gcloud${NC}"
echo -e "4. Go back to Triggers and click ${BOLD}'Create Trigger'${NC}."
echo -e "5. Configure the Trigger:"
echo -e "   - Name: ${BOLD}deploy-on-push${NC}"
echo -e "   - Event: ${BOLD}Push to a branch${NC}"
echo -e "   - Source Repository: ${BOLD}bluechristopher/flask-gcloud${NC}"
echo -e "   - Branch: ${BOLD}^main$${NC} (or your primary branch)"
echo -e "   - Configuration: ${BOLD}Cloud Build configuration file (yaml or json)${NC}"
echo -e "   - Cloud Build file location: ${BOLD}cloudbuild.yaml${NC}"
echo -e "   - Under ${BOLD}'Substitution variables'${NC}, add these variables:"
echo -e "     * ${BOLD}_LOCATION${NC}  :  ${GREEN}${REGION}${NC}"
echo -e "     * ${BOLD}_REPO_NAME${NC} :  ${GREEN}${REPO_NAME}${NC}"
echo -e "     * ${BOLD}_SERVICE_NAME${NC}: ${GREEN}${SERVICE_NAME}${NC}"
echo -e "     * ${BOLD}_BUCKET_NAME${NC}:  ${GREEN}${BUCKET_NAME}${NC}"
echo -e "6. Save the trigger. Now, any push to GitHub will automatically deploy! \n"
