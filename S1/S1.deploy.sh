#!/usr/bin/env bash
set -e

# ------------------------------------
# Description: Deploy Azure Resource Groups, VNets, Subnets, NSGs, Log Analytics Workspace, 
#              NSP, VNet Flow Logs, Diagnostics & Observability dashboards using YAML config
# Usage:
#   ./S1.deploy.sh [ACTION] [CONFIG_FILE]
#
# Arguments:
#   ACTION       - Optional. What to do: "plan" or "apply". Default is "plan".
#                  plan  : Only prints what would be created, does not apply changes.
#                  apply : Actually creates resources in Azure.
#   CONFIG_FILE  - Optional. Path to YAML configuration file. Default: ./S1.yaml
#
#
# Requirements:
#   - Azure CLI (az) installed and logged in
#   - yq installed for parsing YAML
#   - Bash 4+ for array support

# ------------------------------------
# UI Componenets and Arguments
# ------------------------------------
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

ACTION=${1:-plan}  # default: plan
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${2:-$SCRIPT_DIR/S1.yaml}" # default: S1.yaml

echo -e "${CYAN}Action:${NC} $ACTION"
echo -e "${CYAN}Loading config from ${NC} $CONFIG_FILE"

if [[ "$ACTION" == "plan" ]]; then
  echo -e "${YELLOW}Plan mode: No resources will be created${NC}"
fi


# ---------------------------------------------
# Load core variables from YAML
# ---------------------------------------------
ORG=$(yq -r '.organization_name' "$CONFIG_FILE")
PATTERN_TYPE=$(yq -r '.pattern_type' "$CONFIG_FILE")
REGION=$(yq -r '.region' "$CONFIG_FILE")
REGION_SHORT=$(yq -r ".region_map.$REGION" "$CONFIG_FILE")
# Get current timestamp
DEPLOYED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Convert YAML tags to Azure CLI format: key=value key2=value2 ...
TAGS=$(yq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(" ")' "$CONFIG_FILE")
TAGS="$TAGS deployed_at=$DEPLOYED_AT"

# ---------------------------------------------
# Load naming pattern for RGs
# ---------------------------------------------
RG_PATTERN=$(yq -r '.naming.resource_group' "$CONFIG_FILE")
VNET_PATTERN=$(yq -r '.naming.vnet' "$CONFIG_FILE")
SUBNET_PATTERN=$(yq -r '.naming.subnet' "$CONFIG_FILE")
NSP_PATTERN=$(yq -r '.naming.nsp' "$CONFIG_FILE")
LAW_PATTERN=$(yq -r '.naming.law' "$CONFIG_FILE")
STORAGE_ACCOUNT_PATTERN=$(yq -r '.naming.storage' "$CONFIG_FILE")

# ---------------------------------------------
# Function to render a naming pattern
# Supports: {region} {org} {pattern} {name}
# ---------------------------------------------
render_name() {
    local template="$1"
    local name="$2"
    local suffix="${3:-01}"   # default suffix is 01

    # ensure suffix starts with "-"
    [[ "$suffix" != -* ]] && suffix="-$suffix"

    local out="$template"
    out="${out//\{region\}/$REGION_SHORT}"
    out="${out//\{org\}/$ORG}"
    out="${out//\{pattern\}/$PATTERN_TYPE}"
    out="${out//\{name\}/$name}"

    # Append suffix
    out="${out}${suffix}"

    echo "$out"
}


# ----------------------
# Read RG list from YAML
# ----------------------
RG_LIST=()
while IFS= read -r rg; do
    RG_LIST+=("$rg")
done < <(yq '.resource_groups[]' "$CONFIG_FILE")

# ---------------------------------------------
# Deploy Resource Groups
# ---------------------------------------------
echo -e "${CYAN}Region short:${NC} $REGION_SHORT"
echo -e "${CYAN}Deploying Resource Groups...${NC}"


for rg in "${RG_LIST[@]}"; do
    rg_name=$(render_name "$RG_PATTERN" "$rg")

    echo -e "${GREEN}Creating RG:${NC} $rg_name"
    if [[ "$ACTION" == "apply" ]]; then
        az group create --name "$rg_name" --location "$REGION" --tags "$TAGS"
    fi
done

# ---------------------------------------------
# Deploy Network
# ---------------------------------------------
echo -e "${CYAN}Deploying Network Components...${NC}"
vnet_count=$(yq e '.vnets | length' "$CONFIG_FILE")

if [[ "$vnet_count" -eq 0 ]]; then
    echo -e "${YELLOW}No VNets defined. Skipping network deployment.${NC}"
else
  RG_NETWORK=$(render_name "$RG_PATTERN" "${RG_LIST[0]}") # need to fix later

  for i in $(seq 0 $((vnet_count - 1))); do
      VNET_YAML_NAME=$(yq e ".vnets[$i].name" "$CONFIG_FILE")
      VNET_CIDR=$(yq e ".vnets[$i].cidr" "$CONFIG_FILE")
      VNET_NAME=$(render_name "$VNET_PATTERN" "$VNET_YAML_NAME")

      echo -e "${GREEN}Creating VNet:${NC} $VNET_NAME ($VNET_CIDR)"
      if [[ "$ACTION" == "apply" ]]; then
          az network vnet create \
              --resource-group "$RG_NETWORK" \
              --name "$VNET_NAME" \
              --address-prefix "$VNET_CIDR" \
              --tags "$TAGS"
      fi

      # Loop over subnets
      subnet_count=$(yq e ".vnets[$i].subnets | length" "$CONFIG_FILE")
      for j in $(seq 0 $((subnet_count - 1))); do
          SUBNET_YAML_NAME=$(yq e ".vnets[$i].subnets[$j].name" "$CONFIG_FILE")
          SUBNET_CIDR=$(yq e ".vnets[$i].subnets[$j].cidr" "$CONFIG_FILE")
          SUBNET_NAME=$(render_name "$SUBNET_PATTERN" "$SUBNET_YAML_NAME")
          NSG_NAME="nsg-$SUBNET_NAME"
          RULES=$(yq -r ".vnets[$i].subnets[$j].nsg_rules" "$CONFIG_FILE")
          echo -e "  ${GREEN}→ Creating NSG:${NC} $NSG_NAME"
          if [[ "$ACTION" == "apply" ]]; then
            az network nsg create \
                --resource-group "$RG_NETWORK" \
                --name "$NSG_NAME" \
                --tags "$TAGS"
          fi
          for RULE in $RULES; do
            [[ -z "$RULE" || "$RULE" == "null" ]] && continue
            PRIORITY=$(yq -r ".custom_nsg_rules.$RULE.priority" "$CONFIG_FILE")
            PROTOCOL=$(yq -r ".custom_nsg_rules.$RULE.protocol" "$CONFIG_FILE")
            DIRECTION=$(yq -r ".custom_nsg_rules.$RULE.direction" "$CONFIG_FILE")
            SRC=$(yq -r ".custom_nsg_rules.$RULE.source" "$CONFIG_FILE")
            SRC_PORTS=$(yq -r ".custom_nsg_rules.$RULE.source_ports" "$CONFIG_FILE")
            DST=$(yq -r ".custom_nsg_rules.$RULE.destination" "$CONFIG_FILE")
            DST_PORTS=$(yq -r ".custom_nsg_rules.$RULE.destination_ports" "$CONFIG_FILE")
            echo -e "    ${GREEN}→ NSG Rule:${NC} $RULE (priority=$PRIORITY, port=${DST_PORTS})"
            if [[ "$ACTION" == "apply" ]]; then
                az network nsg rule create \
                    --resource-group "$RG_NETWORK" \
                    --nsg-name "$NSG_NAME" \
                    --name "$RULE" \
                    --priority "$PRIORITY" \
                    --protocol "$PROTOCOL" \
                    --direction "$DIRECTION" \
                    --source-address-prefix "$SRC" \
                    --source-port-range "$SRC_PORTS" \
                    --destination-address-prefix "$DST" \
                    --destination-port-range "$DST_PORTS" \
                    --access allow
            fi
          done

          echo -e "  ${GREEN}→ Creating Subnet:${NC} $SUBNET_NAME ($SUBNET_CIDR)"
          if [[ "$ACTION" == "apply" ]]; then
            az network vnet subnet create \
                --resource-group "$RG_NETWORK" \
                --vnet-name "$VNET_NAME" \
                --name "$SUBNET_NAME" \
                --address-prefixes "$SUBNET_CIDR" \
                --network-security-group "$NSG_NAME"
          fi
      done
  done

fi

if [[ "$(yq e '.nsp | length' "$CONFIG_FILE")" -eq 0 ]]; then
    echo -e "${YELLOW}No Network Security Perimeter defined. Skipping NSP deploy.${NC}"
else
    RG_NETWORK=$(render_name "$RG_PATTERN" "${RG_LIST[0]}") # need to fix later
    NSP_YAML_NAME=$(yq e '.nsp' "$CONFIG_FILE")
    NSP_NAME=$(render_name "$NSP_PATTERN" "$NSP_YAML_NAME")
    echo -e "${GREEN}Creating NSP:${NC} $NSP_NAME"
    if [[ "$ACTION" == "apply" ]]; then
        az network perimeter create --name "$NSP_NAME" --resource-group "$RG_NETWORK"  --location "$REGION" --tags "$TAGS"
    fi

fi

# ---------------------------------------------
# Deploy Monitoring Resources
# ---------------------------------------------
echo -e "${CYAN}Deploying Monitoring Resources...${NC}"
if [[ "$(yq e '.log_analytics_workspace | length' "$CONFIG_FILE")" -eq 0 ]]; then
    echo -e "${YELLOW}No Log Analytics Workspace defined. Skipping LAW deploy.${NC}"
else
    RG_MONITOR=$(render_name "$RG_PATTERN" "${RG_LIST[2]}") # need to fix later
    LAW_YAML_NAME=$(yq e '.log_analytics_workspace' "$CONFIG_FILE")
    LAW_NAME=$(render_name "$LAW_PATTERN" "$LAW_YAML_NAME")
    echo -e "${GREEN}Creating LAW:${NC} $LAW_NAME"
    if [[ "$ACTION" == "apply" ]]; then
        az monitor log-analytics workspace create --resource-group "$RG_MONITOR" --workspace-name "$LAW_NAME" --tags "$TAGS"
    fi    
fi

if [[ "$(yq e '.is_network_watcher_needed' "$CONFIG_FILE")" == "yes" ]]; then
    RG_MONITOR=$(render_name "$RG_PATTERN" "${RG_LIST[2]}") # need to fix later
    echo -e "${GREEN}Deploying network watcher for region:${NC} $REGION"
    if [[ "$ACTION" == "apply" ]]; then
        az network watcher configure --resource-group "RG_MONITOR" --locations "$REGION" --enabled
    fi 
fi

# ---------------------------------------------
# Diagnostics & Traffic Analytics
# ---------------------------------------------

if [[ "$(yq e '.is_diagnostics_enabled' "$CONFIG_FILE")" == "yes" ]]; then
    echo -e "${CYAN}Enabling Diagnostics & Traffic Analytics...${NC}"
    RG_MONITOR=$(render_name "$RG_PATTERN" "${RG_LIST[2]}") # needs fix
    RG_NETWORK=$(render_name "$RG_PATTERN" "${RG_LIST[0]}") # need to fix later
    LAW_YAML_NAME=$(yq e '.log_analytics_workspace' "$CONFIG_FILE")
    LAW_NAME=$(render_name "$LAW_PATTERN" "$LAW_YAML_NAME")
    if [[ "$ACTION" == "apply" ]]; then
        LAW_ID=$(az monitor log-analytics workspace show \
            --resource-group "$RG_MONITOR" \
            --workspace-name "$LAW_NAME" \
            --query id -o tsv)
    fi
    
    echo "LAW_ID: $LAW_ID"

    # deploy Storage account for flow logs
    STORAGE_ACCOUNT_YAML_NAME=$(yq e '.diagnostics_storage_account' "$CONFIG_FILE")
    STORAGE_ACCOUNT_NAME=$(render_name "$STORAGE_ACCOUNT_PATTERN" "$STORAGE_ACCOUNT_YAML_NAME" "01")
    STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME//-/} # Remove hyphens
    if [[ "$ACTION" == "apply" ]]; then
        # Create storage account if it doesn't exist
        az storage account create \
            --name "$STORAGE_ACCOUNT_NAME" \
            --resource-group "$RG_MONITOR" \
            --location "$REGION" \
            --sku Standard_LRS \
            --kind StorageV2 \
            --tags "$TAGS"

        # Get the full resource ID for flow log configuration
        STORAGE_ID=$(az storage account show \
            --name "$STORAGE_ACCOUNT_NAME" \
            --resource-group "$RG_MONITOR" \
            --query id -o tsv)
    fi
    echo -e "${GREEN}Creating storage account for flow logs:${NC} $STORAGE_ACCOUNT_NAME"

    echo -e "${GREEN}Using LAW:${NC} $LAW_ID"
    echo -e "${GREEN}Using Storage:${NC} $STORAGE_ID"

    # ---------------------------------------------------
    # Enable Flow logs on vnet
    # ---------------------------------------------------
    echo -e "${CYAN}Configuring VNET flow logs...${NC}"
    vnet_count=$(yq e '.vnets | length' "$CONFIG_FILE")

    for i in $(seq 0 $((vnet_count - 1))); do
        VNET_YAML_NAME=$(yq e ".vnets[$i].name" "$CONFIG_FILE")
        VNET_NAME=$(render_name "$VNET_PATTERN" "$VNET_YAML_NAME")
        
        echo -e "${GREEN}Enabling VNet flow logs for VNet:${NC} $VNET_NAME"
        
        if [[ "$ACTION" == "apply" ]]; then
            az network watcher flow-log create \
                --location "$REGION" \
                --resource-group "$RG_NETWORK" \
                --name "flow-$VNET_NAME" \
                --vnet "$VNET_NAME" \
                --storage-account "$STORAGE_ID" \
                --traffic-analytics true \
                --workspace "$LAW_ID" \
                --retention 30 \
                --interval 10
        fi
    done

    # ---------------------------------------------------
    # Enable Diagnostics for NSP
    # ---------------------------------------------------
    if [[ "$(yq e '.nsp | length' "$CONFIG_FILE")" -gt 0 ]]; then
        NSP_YAML_NAME=$(yq e '.nsp' "$CONFIG_FILE")
        NSP_NAME=$(render_name "$NSP_PATTERN" "$NSP_YAML_NAME")

        echo -e "${CYAN}Configuring NSP Diagnostics for:${NC} $NSP_NAME"
        if [[ "$ACTION" == "apply" ]]; then
            az monitor diagnostic-settings create \
                --name "diag-set-01" \
                --resource "$NSP_NAME" \
                --resource-group "$RG_NETWORK" \
                --resource-type "Microsoft.Network/networkSecurityPerimeters" \
                --workspace "$LAW_ID" \
                --logs '[{"categoryGroup": "allLogs", "enabled": true}]' \
                --output none
            echo -e "   ${GREEN}→ NSP diagnostics enabled (allLogs)${NC}"
        fi       
    fi

else
    echo -e "${YELLOW}Diagnostics disabled via YAML. Skipping.${NC}"
fi


# ---------------------------------------------
# Deploy a Dashboard for observability
# ---------------------------------------------
if [[ "$(yq e '.is_dashbord_needed' "$CONFIG_FILE")" == "yes" ]]; then
    # Need to fix later
    echo -e "${YELLOW}Due to an open issue/bug in az cli dashboard (experimental) command. requesting you to PLEASE DEPLOY THE DASHBOARD MANUALLY using the file: S1.dashboard.json ${NC}" 
fi



# ---------------------------------------------
# Test WorkLoads deployment
# ---------------------------------------------

