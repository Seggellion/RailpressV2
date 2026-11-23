#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="$(realpath "${1:?absolute empty download directory required}")"
[[ "$scratch" == "$1" && -d "$scratch" && -O "$scratch" && -w "$scratch" ]]
[[ -z "$(ls -A -- "$scratch")" ]]
umask 077

verify_vendor() {
  local archive=$1 signature_url=$2 key_url=$3 fingerprint=$4
  mkdir -m 700 "$scratch/gnupg-$archive"
  local keyring="$scratch/gnupg-$archive"
  download "$signature_url" "$scratch/$archive.asc"
  download "$key_url" "$scratch/$archive.key"
  gpg --batch --homedir "$keyring" --import "$scratch/$archive.key"
  gpg --batch --homedir "$keyring" --status-fd 1 --verify "$scratch/$archive.asc" "$scratch/$archive" |
    awk -v pin="$fingerprint" '$2 == "VALIDSIG" && $3 == pin {matched = 1} END {exit !matched}'
}
download() {
  curl --silent --show-error --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 300 --retry 3 --output "$2" "$1"
}
while read -r sha name url; do
  [[ -n "$sha" && "$sha" != \#* ]] || continue
  [[ "$sha" =~ ^[0-9a-f]{64}$ && "$name" =~ ^[a-zA-Z0-9_.-]+$ && "$url" == https://* ]]
  download "$url" "$scratch/$name"
  (cd "$scratch" && printf '%s  %s\n' "$sha" "$name" | sha256sum --check --strict)
done < scripts/native/ci-inputs.txt
verify_vendor mysql-8.4.13.tar.xz 'https://dev.mysql.com/downloads/gpg/?file=mysql-8.4.13-linux-glibc2.28-x86_64-minimal.tar.xz&p=23' \
  https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 BCA43417C3B485DD128EC6D4B7B3B788A8D3785C
verify_vendor nginx-1.30.6.tar.gz https://nginx.org/download/nginx-1.30.6.tar.gz.asc \
  https://nginx.org/keys/pluknet.key D6786CE303D9A9022998DC6CC8464D549AF75C0A
