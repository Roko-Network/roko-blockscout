#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  deploy/publish-token-assets.sh --source DIR [options] [--execute]

Publish a validated ROKO testnet token-list.json and all artwork referenced by
that list to the persistent explorer asset directory. The proxy serves these
files directly, so this does not rebuild or restart the frontend.

Options:
  --source DIR       Directory containing token-list.json and its image files.
  --host TARGET      SSH target (default: deploy@10.0.42.111).
  --identity FILE    SSH identity (default: operator agentic_ed25519 key).
  --port PORT        SSH port (default: 22).
  --execute          Publish after validation. Without this flag, dry-run only.
  -h, --help         Show this help.
EOF
}

die() {
  printf 'publish-token-assets: %s\n' "$*" >&2
  exit 1
}

source_dir=
ssh_target=deploy@10.0.42.111
ssh_identity=/home/roctinam/.ssh/agentic_ed25519
ssh_port=22
execute=0
public_base=https://explorer.roko.network/assets/token-icons
remote_dir=/data/roko-explorer/runtime/token-icons

while (($#)); do
  case "$1" in
    --source)
      (($# >= 2)) || die '--source requires a directory'
      source_dir=$2
      shift 2
      ;;
    --host)
      (($# >= 2)) || die '--host requires an SSH target'
      ssh_target=$2
      shift 2
      ;;
    --identity)
      (($# >= 2)) || die '--identity requires a file'
      ssh_identity=$2
      shift 2
      ;;
    --port)
      (($# >= 2)) || die '--port requires a value'
      ssh_port=$2
      shift 2
      ;;
    --execute)
      execute=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$source_dir" ]] || die '--source is required'
source_dir=$(realpath -e "$source_dir")
[[ -d "$source_dir" ]] || die "source directory not found: $source_dir"
[[ -r "$source_dir/token-list.json" ]] ||
  die "token-list.json not found in $source_dir"
[[ "$ssh_port" =~ ^[0-9]+$ ]] || die "invalid SSH port: $ssh_port"
[[ -r "$ssh_identity" ]] || die "SSH identity is not readable: $ssh_identity"
command -v jq >/dev/null || die 'jq is required'
command -v tar >/dev/null || die 'tar is required'
command -v ssh >/dev/null || die 'ssh is required'
command -v scp >/dev/null || die 'scp is required'

token_list=$source_dir/token-list.json
jq -e --arg base "$public_base/" '
  (.name | type == "string" and length > 0) and
  (.version.major | type == "number") and
  (.version.minor | type == "number") and
  (.version.patch | type == "number") and
  (.tokens | type == "array" and length > 0) and
  (all(.tokens[];
    .chainId == 52370 and
    (.address | test("^0x[0-9A-Fa-f]{40}$")) and
    (.name | type == "string" and length > 0) and
    (.symbol | type == "string" and length > 0) and
    (.decimals | type == "number") and
    (.logoURI | startswith($base))
  )) and
  (([.tokens[].address | ascii_downcase] | length) ==
    ([.tokens[].address | ascii_downcase] | unique | length))
' "$token_list" >/dev/null || die 'token-list.json failed ROKO testnet validation'

mapfile -t assets < <(
  jq -r '.tokens[].logoURI | split("?")[0] | split("/")[-1]' "$token_list" |
    sort -u
)
((${#assets[@]} > 0)) || die 'token list does not reference any artwork'

for asset in "${assets[@]}"; do
  [[ "$asset" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.(jpg|jpeg|png|svg|webp)$ ]] ||
    die "unsafe or unsupported asset filename: $asset"
  [[ -f "$source_dir/$asset" ]] ||
    die "referenced artwork is missing: $source_dir/$asset"
  [[ -s "$source_dir/$asset" ]] ||
    die "referenced artwork is empty: $source_dir/$asset"
done

version=$(jq -r '.version | "\(.major).\(.minor).\(.patch)"' "$token_list")
printf 'Validated token list v%s for chain 52370: %s tokens, %s assets.\n' \
  "$version" "$(jq '.tokens | length' "$token_list")" "${#assets[@]}"
printf 'Assets:\n'
printf '  %s\n' "${assets[@]}"

if ((execute == 0)); then
  printf 'Dry run complete. Re-run with --execute to publish.\n'
  exit 0
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive=$(mktemp /tmp/roko-token-assets.XXXXXX.tar)
remote_archive=/tmp/roko-token-assets-$stamp-$$.tar
cleanup() {
  rm -f "$archive"
}
trap cleanup EXIT

tar -C "$source_dir" -cf "$archive" "${assets[@]}" token-list.json

ssh_args=(
  -i "$ssh_identity"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -p "$ssh_port"
)
scp_args=(
  -i "$ssh_identity"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -P "$ssh_port"
)

scp "${scp_args[@]}" "$archive" "$ssh_target:$remote_archive"

ssh "${ssh_args[@]}" "$ssh_target" sudo bash -s -- \
  "$remote_archive" "$remote_dir" "$stamp" "${assets[@]}" token-list.json <<'REMOTE'
set -euo pipefail
archive=$1
target=$2
stamp=$3
shift 3
files=("$@")
stage=$(mktemp -d /tmp/roko-token-assets.XXXXXX)
cleanup() {
  rm -rf "$stage"
  rm -f "$archive"
}
trap cleanup EXIT

tar --no-same-owner --no-same-permissions -xf "$archive" -C "$stage"
install -d -m 0755 "$target" "$target/history/$stamp"

for name in "${files[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
  test -s "$stage/$name"
  if test -f "$target/$name"; then
    install -m 0644 "$target/$name" "$target/history/$stamp/$name"
  fi
done

# Publish artwork first and the manifest last so readers never observe a
# manifest that points at a file not yet installed.
for name in "${files[@]}"; do
  test "$name" = token-list.json && continue
  install -m 0644 "$stage/$name" "$target/$name"
done
install -m 0644 "$stage/token-list.json" "$target/token-list.json"

docker compose \
  --project-directory /data/roko-explorer/runtime \
  -f /data/roko-explorer/runtime/docker-compose.yml \
  exec -T proxy nginx -t </dev/null

# Ask the running importer to refresh immediately; no backend restart needed.
docker exec backend bin/blockscout rpc \
  'pid = Process.whereis(Explorer.Market.Fetcher.TokenList) || raise "token-list importer is not running"; send(pid, :fetch); IO.puts("Token-list refresh queued.")'
REMOTE

for name in "${assets[@]}" token-list.json; do
  local_hash=$(sha256sum "$source_dir/$name" | awk '{print $1}')
  public_hash=$(
    curl --fail --silent --show-error \
      "$public_base/$name?published=$stamp" |
      sha256sum |
      awk '{print $1}'
  )
  [[ "$local_hash" = "$public_hash" ]] ||
    die "public checksum mismatch for $name"
done

printf 'Published token metadata and artwork without a frontend rebuild.\n'
