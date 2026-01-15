#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =========================================================
# GLOBALS / CONSTANTS
# =========================================================
ACTION="${1:-plan}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${2:-$SCRIPT_DIR/S1/S1.yaml}"

[[ "$ACTION" != "plan" && "$ACTION" != "apply" ]] && {
  echo "Usage: $0 [plan|apply] [config.yaml]"
  exit 1
}
# =========================================================
# UI / LOGGING
# =========================================================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${CYAN}ℹ $*${NC}"; }
ok()   { echo -e "${GREEN}✔ $* ${NC}"; }
warn() { echo -e "${YELLOW}⚠ $* ${NC}"; }
die()  { echo -e "${RED}✖${NC} $*"; exit 1; }

# =========================================================
# YAML ACCESSORS
# =========================================================
yaml()   { yq -e "$1" "$CONFIG_FILE"; }
yaml_r() { yq -r "$1" "$CONFIG_FILE"; }
# =========================================================
# NAMING ENGINE
# =========================================================
render_name() {
  local template="$1" name="$2" suffix="${3:-01}"

  [[ "$suffix" != -* ]] && suffix="-$suffix"

  local out="$template"
  out="${out//\{region\}/$REGION_SHORT}"
  out="${out//\{org\}/$ORG}"
  out="${out//\{pattern\}/$PATTERN_TYPE}"
  out="${out//\{name\}/$name}"

  echo "${out}${suffix}"
}

# =========================================================
# AZURE HELPERS
# =========================================================
init_context() {
  ORG=$(yaml_r '.organization_name') || die "organization_name missing"
  PATTERN_TYPE=$(yaml_r '.pattern_type') || die "pattern_type missing"
  REGION=$(yaml_r '.region') || die "region missing"
  REGION_SHORT=$(yaml_r ".region_map.$REGION") || die "region_map.$REGION missing"

  TAGS=()
  while IFS= read -r tag; do
    TAGS+=("$tag")
  done < <(
    yaml_r '.tags // {} | to_entries | map("\(.key)=\(.value)") | .[]'
  )
  TAGS+=("deployed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")")
}
apply_or_plan() {
  if [[ "$ACTION" == "apply" ]]; then
    "$@"
  else
    printf "%b[PLAN]%b " "$YELLOW" "$NC"
    printf "%q " "$@"
    printf "\n"
  fi
}
deploy_resource_groups() {
  log "Deploying Resource Groups"

  rg_pattern=$(yaml_r '.naming.resource_group')

  # Loop over all RGs defined in YAML
  for name in $(yaml_r '.resource_groups[].name'); do
    rg_name=$(render_name "$rg_pattern" "$name")
    ok "Creating Resource Group: $rg_name"
    apply_or_plan az group create -n "$rg_name" -l "$REGION" --tags "${TAGS[@]}"
  done
}
deploy_network() {
  log "Deploying Network Components..."

  # Read naming patterns locally
  rg_pattern=$(yaml_r '.naming.resource_group')
  vnet_pattern=$(yaml_r '.naming.vnet')
  subnet_pattern=$(yaml_r '.naming.subnet')
  nsp_pattern=$(yaml_r '.naming.nsp')

  # Determine network RG from YAML
  rg_network=$(render_name "$rg_pattern" "$(yaml_r '.resource_groups[] | select(.type=="network") | .name')")
  [[ -z "$rg_network" ]] && { warn "No RG with type 'network' found. Skipping network deploy."; return; }

  vnet_count=$(yaml '.vnets | length')
  [[ "$vnet_count" -eq 0 ]] && { warn "No VNets defined. Skipping network deploy."; return; }

  for i in $(seq 0 $((vnet_count - 1))); do
    vnet_yaml=".vnets[$i]"
    vnet_name=$(render_name "$vnet_pattern" "$(yaml_r "$vnet_yaml.name")")
    vnet_cidr=$(yaml_r "$vnet_yaml.cidr")

    ok "Creating VNet: $vnet_name ($vnet_cidr)"
    apply_or_plan az network vnet create \
      --resource-group "$rg_network" \
      --name "$vnet_name" \
      --address-prefix "$vnet_cidr" \
      --tags "${TAGS[@]}"

    subnet_count=$(yaml "$vnet_yaml.subnets | length")
    for j in $(seq 0 $((subnet_count - 1))); do
      subnet_yaml="$vnet_yaml.subnets[$j]"
      subnet_name=$(render_name "$subnet_pattern" "$(yaml_r "$subnet_yaml.name")")
      subnet_cidr=$(yaml_r "$subnet_yaml.cidr")
      nsg_name="nsg-$subnet_name"

      ok "→ Creating NSG: $nsg_name"
      apply_or_plan az network nsg create \
        --resource-group "$rg_network" \
        --name "$nsg_name" \
        --tags "${TAGS[@]}"

      yaml_r "$subnet_yaml.nsg_rules[]" | while IFS= read -r rule; do
        [[ -z "$rule" || "$rule" == "null" ]] && continue

        priority=$(yaml_r ".custom_nsg_rules.$rule.priority")
        protocol=$(yaml_r ".custom_nsg_rules.$rule.protocol")
        direction=$(yaml_r ".custom_nsg_rules.$rule.direction")
        src=$(yaml_r ".custom_nsg_rules.$rule.source")
        src_ports=$(yaml_r ".custom_nsg_rules.$rule.source_ports")
        dst=$(yaml_r ".custom_nsg_rules.$rule.destination")
        dst_ports=$(yaml_r ".custom_nsg_rules.$rule.destination_ports")

        ok "→ NSG Rule: $rule (priority=$priority, port=$dst_ports)"
        apply_or_plan az network nsg rule create \
          --resource-group "$rg_network" \
          --nsg-name "$nsg_name" \
          --name "$rule" \
          --priority "$priority" \
          --protocol "$protocol" \
          --direction "$direction" \
          --source-address-prefix "$src" \
          --source-port-range "$src_ports" \
          --destination-address-prefix "$dst" \
          --destination-port-range "$dst_ports" \
          --access allow
      done

      ok "→ Creating Subnet: $subnet_name ($subnet_cidr)"
      apply_or_plan az network vnet subnet create \
        --resource-group "$rg_network" \
        --vnet-name "$vnet_name" \
        --name "$subnet_name" \
        --address-prefixes "$subnet_cidr" \
        --network-security-group "$nsg_name"
    done
  done

  # NSP
  nsp_yaml_name=$(yaml_r '.nsp // empty')
  [[ -z "$nsp_yaml_name" ]] && { warn "No NSP defined. Skipping."; return; }

  nsp_name=$(render_name "$nsp_pattern" "$nsp_yaml_name")
  ok "Creating NSP: $nsp_name"

  apply_or_plan az network perimeter create \
    --name "$nsp_name" \
    --resource-group "$rg_network" \
    --location "$REGION" \
    --tags "${TAGS[@]}"

  apply_or_plan az network perimeter profile create \
    -n "defaultProfile" \
    --perimeter-name "$nsp_name" \
    -g "$rg_network"

  yaml_r '.custom_nsp_rules | keys | .[]' | while IFS= read -r rule; do
    source=$(yaml_r ".custom_nsp_rules.$rule.source")
    ok "→ NSP Rule: $rule (SOURCE=$source)"
    apply_or_plan az network perimeter profile access-rule create \
      --name "$rule" \
      --profile-name "defaultProfile" \
      --perimeter-name "$nsp_name" \
      --resource-group "$rg_network" \
      --address-prefixes "$source"
  done
}





# =========================================================
# Main flow
# =========================================================
main() {
  log "Action: $ACTION"
  log "Config: $CONFIG_FILE"
  if [[ "$ACTION" == "plan" ]]; then
    warn "Plan mode: No resources will be created"
  fi
  # Initilise all vars from yaml
  init_context
  # Azure deployments
  deploy_resource_groups
  deploy_network
  log "Deployment complete"
}


# =========================================================
# MAIN
# =========================================================
main "$@"
