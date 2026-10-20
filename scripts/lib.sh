#!/usr/bin/env bash
#
# Shared helpers. Sourced by every script under scripts/, never run directly.
#
# Part 1 had one cluster. Part 2 has two sites, par on Scaleway and fin on
# Verda, each with its own Terraform root, kubeconfig and known_hosts. A script
# picks its site with use_site before touching any of them.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034 # consumed by the scripts that source this file
SESSION_LOG="$REPO_ROOT/.sessions.csv"
SESSION_LOG_HEADER="site,started_at,ended_at,node_name,node_type,hourly_rate,currency"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# Sets the paths that differ between sites. Every script calls it once, right
# after sourcing this file.
use_site() {
  SITE="${1:-}"
  case "$SITE" in
    par | fin) ;;
    *) die "unknown site '$SITE', expected par or fin" ;;
  esac
  # shellcheck disable=SC2034 # consumed by the scripts that source this file
  {
    TF_DIR="$REPO_ROOT/terraform/$SITE"
    KUBECONFIG_PATH="$REPO_ROOT/kubeconfig-$SITE"
    KNOWN_HOSTS="$REPO_ROOT/.ssh-known-hosts-$SITE"
    GPU_TFVARS="$TF_DIR/gpu.auto.tfvars"
    ARTIFACTS="$REPO_ROOT/docs/artifacts/$SITE"
  }
}

require_tools() {
  local missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "missing required tools: ${missing[*]}"
  fi
}

# Hourly list prices, used by the session log and cost-report.sh. Override them
# in .env if a provider changes its prices. Not an invoice. Scaleway prices are
# in euros before VAT, read from the Scaleway API on 2026-10-19.
set_rates() {
  PAR_GPU_HOURLY_EUR="${PAR_GPU_HOURLY_EUR:-0.7875}"
  PAR_CPU_HOURLY_EUR="${PAR_CPU_HOURLY_EUR:-0.29}"
  PAR_CONTROL_PLANE_HOURLY_EUR="${PAR_CONTROL_PLANE_HOURLY_EUR:-0.055}"
}

# Reads .env if it is there and says nothing if it is not. For scripts that only
# want the rate overrides and never touch a provider API.
load_env_optional() {
  if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091 # path is computed at run time
    source "$REPO_ROOT/.env"
    set +a
  fi
  set_rates
}

# Provider credentials and the SSH key path live in a gitignored .env. Nothing
# in this repository ever reads a credential from anywhere else.
load_env() {
  if [ ! -f "$REPO_ROOT/.env" ]; then
    die ".env not found. Copy .env.example to .env and fill it in."
  fi
  set -a
  # shellcheck disable=SC1091 # path is computed at run time
  source "$REPO_ROOT/.env"
  set +a
  set_rates

  # The Scaleway provider lets these override the zone and region in the
  # Terraform variables, which would make the zone fallback a silent no-op.
  # terraform/par is the single source for placement, so drop them here.
  if [ -n "${SCW_DEFAULT_ZONE:-}" ] || [ -n "${SCW_DEFAULT_REGION:-}" ]; then
    warn "ignoring SCW_DEFAULT_ZONE and SCW_DEFAULT_REGION from .env; placement comes from terraform/par"
    unset SCW_DEFAULT_ZONE SCW_DEFAULT_REGION
  fi

  resolve_ssh_keypair
}

require_scaleway_env() {
  : "${SCW_ACCESS_KEY:?SCW_ACCESS_KEY is not set in .env}"
  : "${SCW_SECRET_KEY:?SCW_SECRET_KEY is not set in .env}"
  : "${SCW_DEFAULT_PROJECT_ID:?SCW_DEFAULT_PROJECT_ID is not set in .env}"
}

# One keypair, one setting.
#
# The public key is derived from the private key and handed to Terraform as
# TF_VAR_ssh_public_key, so the key registered on the nodes is by construction
# the key used to log in to them. The alternative, a public key path in
# terraform.tfvars and a private key path in .env, invites setting one and
# forgetting the other, and you find out ten minutes into an apply when the
# SSH wait loop times out against a node you cannot get into.
resolve_ssh_keypair() {
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-$HOME/.ssh/id_ed25519}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"

  if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
    warn "no SSH private key at $SSH_PRIVATE_KEY_PATH"
    warn "generate one with:"
    warn "  ssh-keygen -t ed25519 -f $SSH_PRIVATE_KEY_PATH -C eu1"
    die "set SSH_PRIVATE_KEY_PATH in .env to point at an existing key"
  fi

  # -P "" supplies an empty passphrase, so an encrypted key fails here instead
  # of hanging on an interactive prompt inside a script.
  local derived
  derived="$(ssh-keygen -y -P "" -f "$SSH_PRIVATE_KEY_PATH" 2>/dev/null || true)"

  if [ -n "$derived" ]; then
    SSH_PUBLIC_KEY="$derived"
  elif [ -f "$SSH_PRIVATE_KEY_PATH.pub" ]; then
    warn "$SSH_PRIVATE_KEY_PATH appears to be passphrase protected"
    warn "using $SSH_PRIVATE_KEY_PATH.pub without being able to prove the two are a pair"
    SSH_PUBLIC_KEY="$(cat "$SSH_PRIVATE_KEY_PATH.pub")"
  else
    die "could not derive a public key from $SSH_PRIVATE_KEY_PATH and there is no .pub beside it"
  fi

  # ssh-keygen -y prints two fields and no comment. Scaleway is happier with a
  # third, and it makes the key recognisable in the console.
  case "$SSH_PUBLIC_KEY" in
    *" "*" "*) : ;;
    *) SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY eu1" ;;
  esac

  export TF_VAR_ssh_public_key="$SSH_PUBLIC_KEY"
}

tf() {
  terraform -chdir="$TF_DIR" "$@"
}

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

# Apply only when the plan destroys or replaces nothing outside what the
# caller is allowed to touch.
#
#   guarded_apply <address regex> <what it is, for the message>
#
# The up and down scripts apply the whole configuration, not a target, so a
# plan that wanted to replace the control plane would go through unprompted and
# take etcd with it. The realistic trigger is Scaleway publishing a newer image
# between sessions. This saves the plan, refuses it if anything outside the
# allowed addresses would be destroyed or replaced, and applies exactly the
# plan that was checked, so nothing can change between the check and the apply.
guarded_apply() {
  local allowed="$1" what="$2"
  local plan="$TF_DIR/guarded.tfplan"
  local unsafe

  tf plan -input=false -out="$plan"

  unsafe="$(terraform -chdir="$TF_DIR" show -no-color "$plan" \
    | grep -E '# .* (will be destroyed|must be replaced)' \
    | grep -Ev "$allowed" || true)"

  if [ -n "$unsafe" ]; then
    rm -f "$plan"
    warn "the plan would destroy or replace something that is not the $what:"
    printf '    %s\n' "$unsafe" >&2
    die "refusing to apply. Run terraform plan in ${TF_DIR#"$REPO_ROOT"/} and read it before going further."
  fi

  tf apply -input=false "$plan"
  rm -f "$plan"
}

apply_gpu_only() {
  guarded_apply 'gpu_node' 'GPU node'
}

# StrictHostKeyChecking is left on, against a repository local known_hosts file
# per site rather than the user's. Per-window nodes get a new public IP every
# time, so their entry is removed on the way down instead of host key checking
# being switched off wholesale.
node_ssh() {
  local host="$1"
  shift
  ssh \
    -i "$SSH_PRIVATE_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "root@$host" "$@"
}

forget_host() {
  local host="$1"
  [ -f "$KNOWN_HOSTS" ] || return 0
  ssh-keygen -f "$KNOWN_HOSTS" -R "$host" >/dev/null 2>&1 || true
}

wait_for_ssh() {
  local host="$1"
  local timeout="${2:-300}"
  local deadline=$(( $(date +%s) + timeout ))

  log "waiting for SSH on $host"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if node_ssh "$host" true >/dev/null 2>&1; then
      log "SSH is up on $host"
      return 0
    fi
    sleep 5
  done
  die "SSH did not come up on $host within ${timeout}s"
}

# Every node bootstrap script touches this marker as its last action, so its
# presence means the first-boot script finished rather than merely started.
wait_for_bootstrap() {
  local host="$1"
  local timeout="${2:-900}"
  local deadline=$(( $(date +%s) + timeout ))

  log "waiting for the bootstrap script on $host to finish"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # fin's bootstrap leaves a marker when it fails, so a broken image costs a
    # minute of GPU time rather than the whole timeout.
    if node_ssh "$host" test -f /var/lib/eu1/bootstrap-failed >/dev/null 2>&1; then
      warn "the bootstrap on $host failed: $(node_ssh "$host" cat /var/lib/eu1/bootstrap-failed 2>/dev/null)"
      node_ssh "$host" tail -n 40 /var/log/eu1-bootstrap.log || true
      die "bootstrap failed on $host"
    fi
    if node_ssh "$host" test -f /var/lib/eu1/bootstrap-complete >/dev/null 2>&1; then
      log "bootstrap complete on $host"
      node_ssh "$host" cat /var/lib/eu1/bootstrap-facts.txt || true
      return 0
    fi
    sleep 10
  done

  warn "bootstrap did not finish on $host within ${timeout}s. Last 40 lines of its log:"
  node_ssh "$host" tail -n 40 /var/log/eu1-bootstrap.log || true
  die "bootstrap timed out on $host"
}

kubectl_cp() {
  KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
}

require_kubeconfig() {
  [ -f "$KUBECONFIG_PATH" ] \
    || die "no kubeconfig at $KUBECONFIG_PATH. Bring the $SITE control plane up first (make $SITE-cluster or make $SITE-cp-up)."
}

########################################
# ArgoCD
#
# The only Helm release a person installs on a site. Everything else arrives
# through the site's app of apps, gitops/sites/<site>/root.yaml, which reads
# gitops/apps/<site>/ recursively.
########################################

bootstrap_argocd() {
  local chart_version="${ARGOCD_CHART_VERSION:-10.9.2}"
  local namespace="${ARGOCD_NAMESPACE:-argocd}"

  log "adding the argo helm repository"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm repo update argo >/dev/null

  log "installing argo-cd $chart_version into $namespace on $SITE"
  helm upgrade --install argocd argo/argo-cd \
    --kubeconfig "$KUBECONFIG_PATH" \
    --version "$chart_version" \
    --namespace "$namespace" \
    --create-namespace \
    --values "$REPO_ROOT/gitops/bootstrap/argocd-values.yaml" \
    --wait \
    --timeout 15m

  log "applying the $SITE root Application"
  kubectl_cp apply -f "$REPO_ROOT/gitops/sites/$SITE/root.yaml"

  log "waiting for ArgoCD to report on the applications it now owns"
  sleep 15
  kubectl_cp -n "$namespace" get applications.argoproj.io || true
}

########################################
# Bring-up timeline
#
# Phase timestamps for a node coming up, from this laptop's NTP-synced clock.
# Minute-scale phases only: anything that needs sub-second timing is taken from
# the node's own clock and the controllers' timestamps instead.
#
#   timeline_start <file>; mark <phase>; mark <phase>; ...
########################################

timeline_start() {
  TIMELINE="$1"
  mkdir -p "$(dirname "$TIMELINE")"
  echo "# $(basename "$TIMELINE"), laptop clock, UTC" > "$TIMELINE"
}

mark() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "$1=$now" >> "$TIMELINE"
  log "$1 at $now"
}

########################################
# Session log
#
# One row per billed node session, so make cost can say what is running and
# what it has cost, across both sites. A local record, not an invoice.
########################################

#   session_open <node> <type> <hourly rate> <currency> [started_at]
# started_at defaults to now. Pass the time the apply started, since billing
# starts when the provider creates the node, not when it is ready.
session_open() {
  local node="$1" type="$2" rate="$3" currency="$4"
  local started="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  [ -f "$SESSION_LOG" ] || echo "$SESSION_LOG_HEADER" > "$SESSION_LOG"
  echo "$SITE,$started,,$node,$type,$rate,$currency" >> "$SESSION_LOG"
}

# Closes the most recent open row for a node.
session_close() {
  local node="$1" ended
  [ -f "$SESSION_LOG" ] || return 0
  ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  awk -F, -v node="$node" -v ended="$ended" '
    BEGIN { OFS = FS }
    { rows[NR] = $0; if (NR > 1 && $4 == node && $3 == "") last = NR }
    END {
      for (i = 1; i <= NR; i++) {
        if (i == last) { split(rows[i], f, FS); f[3] = ended; print f[1], f[2], f[3], f[4], f[5], f[6], f[7] }
        else print rows[i]
      }
    }
  ' "$SESSION_LOG" > "$SESSION_LOG.tmp" && mv "$SESSION_LOG.tmp" "$SESSION_LOG"
}

########################################
# Scaleway leftover sweep
#
# Terraform only knows what it created. In Part 1 an L4 that couldn't boot left
# its root volume behind, unattached and billing, where Terraform couldn't see
# it, and a check of one zone missed it for three days. So this asks the API
# about every zone of the region: every server whose name carries this site's
# prefix, with its state, and every block volume nothing is attached to. It
# only reports. Deleting by a guess is worse than a warning.
########################################

scaleway_sweep() {
  local prefix="$1" region="${2:-fr-par}"
  local api="https://api.scaleway.com" zones zone servers volumes found=0
  zones="${LEFTOVER_ZONES:-$region-1 $region-2 $region-3}"

  for zone in $zones; do
    servers="$(curl -fsS -H "X-Auth-Token: $SCW_SECRET_KEY" "$api/instance/v1/zones/$zone/servers?name=$prefix&per_page=100" 2>/dev/null \
      | jq -r --arg p "$prefix" '.servers[] | select(.name | startswith($p)) | "\(.name) \(.id) state=\(.state) type=\(.commercial_type)"' || true)"
    volumes="$(curl -fsS -H "X-Auth-Token: $SCW_SECRET_KEY" "$api/block/v1alpha1/zones/$zone/volumes?per_page=100" 2>/dev/null \
      | jq -r '.volumes[] | select((.references // []) | length == 0) | "\(.id) \(.name) \(.size / 1e9)GB created=\(.created_at)"' || true)"
    [ -z "$servers" ] && [ -z "$volumes" ] && continue
    found=1
    log "at Scaleway in $zone:"
    [ -n "$servers" ] && sed 's/^/    server /' <<<"$servers"
    [ -n "$volumes" ] && sed 's/^/    UNATTACHED volume /' <<<"$volumes"
  done

  if [ "$found" -eq 0 ]; then
    log "Scaleway shows no $prefix server and no unattached volume in $zones"
  else
    log "the control plane is expected; a stopped CPU worker is expected between uses."
    log "Anything else listed is billing. Check each one is ours, then delete it through the API, server first:"
    log "  curl -X DELETE -H \"X-Auth-Token: \$SCW_SECRET_KEY\" $api/instance/v1/zones/<zone>/servers/<id>"
    log "  curl -X DELETE -H \"X-Auth-Token: \$SCW_SECRET_KEY\" $api/block/v1alpha1/zones/<zone>/volumes/<id>"
  fi
}

########################################
# Verda API, for site fin
#
# OAuth client credentials from .env. The token only ever lives in a shell
# variable, and the secret goes to curl on stdin, not on its command line,
# where any other process could read it.
########################################

VERDA_API="${VERDA_API:-https://api.verda.com/v1}"

require_verda_env() {
  : "${VERDA_CLIENT_ID:?VERDA_CLIENT_ID is not set in .env}"
  : "${VERDA_CLIENT_SECRET:?VERDA_CLIENT_SECRET is not set in .env}"
}

verda_login() {
  VERDA_TOKEN="$(jq -n --arg id "$VERDA_CLIENT_ID" --arg secret "$VERDA_CLIENT_SECRET" \
      '{grant_type: "client_credentials", client_id: $id, client_secret: $secret}' \
    | curl -fsS -X POST "$VERDA_API/oauth2/token" -H 'Content-Type: application/json' --data @- \
    | jq -r '.access_token // empty')"
  [ -n "$VERDA_TOKEN" ] || die "Verda login failed. Check VERDA_CLIENT_ID and VERDA_CLIENT_SECRET in .env."
}

#   verda_get <path relative to /v1, with its query string>
verda_get() {
  curl -fsS -H "Authorization: Bearer $VERDA_TOKEN" "$VERDA_API/$1"
}

#   verda_put <path> <json body>
verda_put() {
  curl -fsS -X PUT -H "Authorization: Bearer $VERDA_TOKEN" -H 'Content-Type: application/json' \
    "$VERDA_API/$1" --data "$2"
}

# Everything of ours still at Verda: every instance (the account holds nothing
# else), every volume, every volume in the trash, and the SSH keys and startup
# scripts with this site's prefix. It only reports. Deleting by a guess is
# worse than a warning.
verda_sweep() {
  local prefix="$1" instances volumes trash keys scripts
  verda_login
  instances="$(verda_get instances | jq -r '.[] | "\(.hostname) \(.id) status=\(.status) type=\(.instance_type) os_volume=\(.os_volume_id)"')"
  volumes="$(verda_get volumes | jq -r '.[] | "\(.name) \(.id) status=\(.status) size=\(.size)GB instance=\(.instance_id // "none")"')"
  trash="$(verda_get volumes/trash | jq -r '.[] | "\(.name) \(.id)"')"
  keys="$(verda_get ssh-keys | jq -r --arg p "$prefix" '.[] | select(.name | startswith($p)) | "\(.name) \(.id)"' 2>/dev/null || true)"
  scripts="$(verda_get scripts | jq -r --arg p "$prefix" '.[] | select(.name | startswith($p)) | "\(.name) \(.id)"' 2>/dev/null || true)"

  if [ -z "$instances$volumes$trash" ]; then
    log "Verda shows no instance, no volume and nothing in the volume trash"
  else
    warn "still at Verda, and billing:"
    [ -n "$instances" ] && sed 's/^/    instance /' <<<"$instances" >&2
    [ -n "$volumes" ] && sed 's/^/    volume /' <<<"$volumes" >&2
    [ -n "$trash" ] && sed 's/^/    volume in trash /' <<<"$trash" >&2
    warn "check each one is ours, then delete it through the API, with its OS volume:"
    warn "  PUT $VERDA_API/instances {\"action\":\"delete\",\"id\":[\"<id>\"],\"volume_ids\":[\"<os volume id>\"],\"delete_permanently\":true}"
    warn "  DELETE $VERDA_API/volumes/<id>"
  fi
  [ -z "$keys$scripts" ] || log "free, kept or left by Terraform: ${keys:+SSH key $keys }${scripts:+startup script $scripts}"
}
