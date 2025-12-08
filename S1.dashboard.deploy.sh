#!/usr/bin/env bash
set -e

RG="rg-weu-vks-s1-surveillance-01"
NAME="S1-main-dashboard"


az portal dashboard create --resource-group "$RG" --name "$NAME" --input-path S1.Dashboard.json --location westeurope
