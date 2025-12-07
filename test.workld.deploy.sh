#!/usr/bin/env bash
set -e

# ---------------------------------------------
# Test WorkLoads deployment
# ---------------------------------------------
REGION="westeurope"
RG_WORKLOAD="rg-weu-vks-s1-workload-01"
RG_NETWORK="rg-weu-vks-s1-landingzone-01"
STORAGE_ACCOUNT_NAME="stvksweus1workload01"
NSP_NAME="nsp-weu-vks-s1-main-01"
STORAGE_ID="/subscriptions/b4bd79bb-2081-4f1e-8cc4-5c600d3bafc2/resourceGroups/rg-weu-vks-s1-workload-01/providers/Microsoft.Storage/storageAccounts/stvksweus1workload01"
NSP_PROFILE_ID="/subscriptions/b4bd79bb-2081-4f1e-8cc4-5c600d3bafc2/resourceGroups/rg-weu-vks-s1-landingzone-01/providers/Microsoft.Network/networkSecurityPerimeters/nsp-weu-vks-s1-main-01/profiles/defaultProfile"
VM_NAME="vm01"
VNET_NAME="vnet-weu-vks-s1-main-01"
USERNAME="azureadmin"
PASSWORD="Password@123456"
VM_SIZE="Standard_B2s"
CLOUD_INIT="#cloud-config
package_upgrade: true
packages:
  - nginx
write_files:
  - owner: www-data:www-data
    path: /var/www/html/index.html
    content: |
      hello world from $VM_NAME"

# # Storage account for testing
# echo "Deploying Storage account: $STORAGE_ACCOUNT_NAME"

# # Create storage account if it doesn't exist
# az storage account create \
#     --name "$STORAGE_ACCOUNT_NAME" \
#     --resource-group "$RG_WORKLOAD" \
#     --location "$REGION" \
#     --sku Standard_LRS \
#     --kind StorageV2 \
#     --identity-type SystemAssigned 
# # Associate paas component to NSP
# echo "Associating Storage Account ID=$STORAGE_ID with NSP Profile id=$NSP_PROFILE_ID ..."

# # Associate the Storage Account with the NSP profile
# az network perimeter association create \
#     --name "${NSP_NAME}-${STORAGE_ACCOUNT_NAME}-assoc-01" \
#     --perimeter-name "$NSP_NAME" \
#     --resource-group "$RG_NETWORK" \
#     --access-mode Enforced \
#     --private-link-resource "{id:$STORAGE_ID}" \
#     --profile "{id:$NSP_PROFILE_ID}"

# Linux VM for testing
az network public-ip create --resource-group $RG_WORKLOAD  --name "$VM_NAME-pip"

SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RG_NETWORK \
  --vnet-name $VNET_NAME \
  --name "snet-compute-room-01" \
  --query "id" -o tsv)


az network nic create \
  --resource-group $RG_WORKLOAD \
  --name "$VM_NAME-nic" \
  --subnet $SUBNET_ID \
  --public-ip-address "$VM_NAME-pip"


# Get NIC ID
NIC_ID=$(az network nic show \
    --resource-group "$RG_WORKLOAD" \
    --name "$VM_NAME-nic" \
    --query "id" -o tsv)

az vm create \
  --resource-group $RG_WORKLOAD \
  --name $VM_NAME \
  --nics "$NIC_ID" \
  --image Ubuntu2204 \
  --size $VM_SIZE \
  --admin-username $USERNAME \
  --admin-password "$PASSWORD" \
  --custom-data <(echo "$CLOUD_INIT")



