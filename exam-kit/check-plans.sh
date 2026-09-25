#!/bin/bash
# Plan every module against live state and classify the result.
# Usage: source vars.live.env && source ~/spn.env && bash check-plans.sh [gen-dir]
GEN="${1:-/tmp/gen}"
for m in policy network platform postgres jumphost aci; do
  printf "%-10s " "$m"
  cd "$GEN/terraform/$m" 2>/dev/null || { echo "MISSING"; continue; }
  terraform init -input=false >/dev/null 2>&1
  OUT=$(terraform plan -input=false -lock=false 2>&1)
  if   echo "$OUT" | grep -q "^No changes";            then echo "CLEAN"
  elif echo "$OUT" | grep -q "save these new output";  then echo "CLEAN (outputs only)"
  elif echo "$OUT" | grep -q "forces replacement";     then echo "*** REPLACEMENT ***"; echo "$OUT" | grep -B2 "forces replacement" | head -6
  elif echo "$OUT" | grep -q "^Plan:";                 then echo "$OUT" | grep "^Plan:"
  else echo "ERROR"; echo "$OUT" | tail -5
  fi
  cd - >/dev/null
done
