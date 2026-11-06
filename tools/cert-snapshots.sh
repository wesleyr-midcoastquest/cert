#!/usr/bin/env bash
# cert-snapshots.sh: list and remove CERT snapshot sets on a Proxmox cluster.
#
# For the Proxmox host owner: run as root on any node of the cluster. CERT
# names every snapshot of a set the same (CERT-<YYMMDD>-<HHMM>-<NN>) on each lab
# VM, so a set is removed as one.
#
#   cert-snapshots.sh list                         every CERT set on lab VMs
#   cert-snapshots.sh remove <name> [--dry-run]    delete one set from every VM that has it
#   cert-snapshots.sh prune --older-than <days> [--dry-run]
#
# Options:
#   --tag <tag>     which VMs count as lab VMs (default: midcoast-lab)
#   --all-vms       look at every VM on the cluster, tagged or not
#   --yes           don't ask (for cron); prune and remove otherwise ask you
#                   to type the set name, or PRUNE
#
# Removing the set of a run that is still open on MGMT means that run can no
# longer be reverted. CERT on MGMT shows open runs; when in doubt, ask the lab
# owner first.
set -euo pipefail

TAG="midcoast-lab"
ALL=0
DRY=0
YES=0
DAYS=""
CMD="${1:-list}"
shift || true
ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --all-vms) ALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    --older-than) DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) if [[ -z "$ARG" ]]; then ARG="$1"; shift; else echo "Unknown argument: $1" >&2; exit 2; fi ;;
  esac
done

command -v pvesh >/dev/null || { echo "pvesh not found: run this on a Proxmox node." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

# One line per CERT snapshot: name<TAB>node<TAB>vmid<TAB>vmname<TAB>snaptime<TAB>vmstate
collect() {
  TAG="$TAG" ALL="$ALL" python3 - <<'PY'
import json, os, subprocess
tag, allvms = os.environ["TAG"], os.environ["ALL"] == "1"
def pvesh(path):
    out = subprocess.run(["pvesh", "get", path, "--output-format", "json"], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else []
for v in pvesh("/cluster/resources?type=vm"):
    if v.get("type") != "qemu" or v.get("template"):
        continue
    tags = [t for t in str(v.get("tags", "")).replace(",", ";").split(";") if t]
    if not allvms and tag not in tags:
        continue
    for s in pvesh(f"/nodes/{v['node']}/qemu/{v['vmid']}/snapshot"):
        name = s.get("name", "")
        if name.startswith("CERT-"):
            print("\t".join([name, v["node"], str(v["vmid"]), v.get("name", ""), str(s.get("snaptime", 0)), "ram" if s.get("vmstate") else "disk"]))
PY
}

list_sets() {
  local rows; rows="$(collect | sort)"
  if [[ -z "$rows" ]]; then echo "No CERT snapshot sets$( [[ $ALL -eq 1 ]] || echo " on VMs tagged $TAG")."; return; fi
  printf '%-22s %-17s %-4s %s\n' "SET" "TAKEN (UTC)" "RAM" "VMS"
  awk -F'\t' '
    { key=$1; vms[key]=vms[key] (vms[key]?", ":"") $4 " (" $3 "@" $2 ")"; t[key]=$5; ram[key]=$6 }
    END { for (k in vms) { cmd="date -u -d @" t[k] " +%Y-%m-%dT%H:%M"; cmd | getline d; close(cmd); printf "%-22s %-17s %-4s %s\n", k, d, (ram[k]=="ram"?"yes":"no"), vms[k] } }
  ' <<<"$rows" | sort
}

remove_set() {
  local name="$1" rows
  [[ "$name" =~ ^CERT-[0-9]{6}-[0-9]{4}-[0-9]{2}$ ]] || { echo "Not a CERT set name: $name" >&2; exit 2; }
  rows="$(collect | awk -F'\t' -v n="$name" '$1==n')"
  [[ -n "$rows" ]] || { echo "No set $name."; return 0; }
  echo "Set $name is on:"
  awk -F'\t' '{ printf "  %s (VM %s on %s)\n", $4, $3, $2 }' <<<"$rows"
  if [[ $DRY -eq 1 ]]; then echo "(dry run: nothing removed)"; return 0; fi
  if [[ $YES -ne 1 ]]; then
    read -r -p "Type the set name to delete it from every VM above: " answer
    [[ "$answer" == "$name" ]] || { echo "Not confirmed; nothing removed."; return 1; }
  fi
  while IFS=$'\t' read -r _ node vmid vmname _ _; do
    echo "  removing from $vmname ($vmid)"
    pvesh delete "/nodes/$node/qemu/$vmid/snapshot/$name" >/dev/null
  done <<<"$rows"
  echo "Removed $name."
}

prune() {
  [[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "prune needs --older-than <days>" >&2; exit 2; }
  local cutoff names
  cutoff=$(( $(date +%s) - DAYS * 86400 ))
  names="$(collect | awk -F'\t' -v c="$cutoff" '$5 < c { print $1 }' | sort -u)"
  [[ -n "$names" ]] || { echo "No CERT sets older than $DAYS day(s)."; return 0; }
  echo "Sets older than $DAYS day(s):"; awk '{ print "  " $0 }' <<<"$names"
  if [[ $DRY -eq 1 ]]; then echo "(dry run: nothing removed)"; return 0; fi
  if [[ $YES -ne 1 ]]; then
    read -r -p "Type PRUNE to delete all of them: " answer
    [[ "$answer" == "PRUNE" ]] || { echo "Not confirmed; nothing removed."; return 1; }
  fi
  local n
  while read -r n; do YES=1 remove_set "$n"; done <<<"$names"
}

case "$CMD" in
  list)   list_sets ;;
  remove) [[ -n "$ARG" ]] || { echo "remove needs a set name (see list)." >&2; exit 2; }; remove_set "$ARG" ;;
  prune)  prune ;;
  *)      echo "Unknown command: $CMD (list | remove <name> | prune --older-than <days>)" >&2; exit 2 ;;
esac
