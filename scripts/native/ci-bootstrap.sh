#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/native/ci-source.sh
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == Linux && "${RUNNER_ARCH:-}" == X64 && $EUID -ne 0 ]]
grep -Fxq 'VERSION_ID="24.04"' /etc/os-release
: "${RUNNER_TEMP:?}" "${GITHUB_PATH:?}" "${GITHUB_ENV:?}"
[[ "$(realpath "$RUNNER_TEMP")" == "$RUNNER_TEMP" && -d "$RUNNER_TEMP" && -O "$RUNNER_TEMP" ]]

sudo apt-get -o Acquire::Retries=3 update -qq
sudo apt-get install -y --no-install-recommends build-essential autoconf bison flex pkg-config \
  libssl-dev libyaml-dev libreadline-dev zlib1g-dev libffi-dev libgmp-dev libicu-dev libxml2-dev \
  libncurses-dev libglib2.0-dev libjpeg-turbo8-dev libpng-dev libexif-dev liblcms2-dev libexpat1-dev \
  libpcre2-dev libaio1t64 libnuma1 libtinfo6 python3-venv gnupg

toolchain=$(mktemp -d "$RUNNER_TEMP/railpress-native.XXXXXXXX")
scratch=$(mktemp -d "$toolchain/build.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
bash scripts/native/ci-fetch.sh "$scratch"

python3 - "$scratch" "$toolchain" <<'PY'
import sys
import tarfile
from pathlib import Path, PurePosixPath

scratch, toolchain = map(Path, sys.argv[1:])
archives = {
    'ruby-3.4.12.tar.gz': 'ruby-3.4.12',
    'postgresql-16.16.tar.bz2': 'postgresql-16.16',
    'mysql-8.4.13.tar.xz': 'mysql-8.4.13-linux-glibc2.28-x86_64-minimal',
    'vips-8.18.7.tar.xz': 'vips-8.18.7',
    'nginx-1.30.6.tar.gz': 'nginx-1.30.6',
    'libwebp-1.6.0-linux-x86-64.tar.gz': 'libwebp-1.6.0-linux-x86-64',
}
for archive, directory in archives.items():
    destination = toolchain if archive.startswith(('mysql-', 'libwebp-')) else scratch
    with tarfile.open(scratch / archive) as source:
        for member in source.getmembers():
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0] != directory or '..' in parts:
                raise ValueError(f'Unexpected archive path in {archive}')
        source.extractall(destination, filter='data')
PY

build() (
  cd "$scratch/$1"
  shift
  ./configure "$@"
  make -j4
  make install
)
build ruby-3.4.12 "--prefix=$toolchain/ruby" --disable-install-doc
build postgresql-16.16 "--prefix=$toolchain/postgresql" --with-openssl --with-icu
build nginx-1.30.6 "--prefix=$toolchain/nginx" "--sbin-path=$toolchain/nginx/usr/sbin/nginx" \
  --with-http_ssl_module --with-http_stub_status_module
python3 -m venv "$scratch/build-tools"
"$scratch/build-tools/bin/pip" install --no-index --no-deps "$scratch"/*.whl
export PATH="$scratch/build-tools/bin:$PATH"
meson setup "$scratch/vips-build" "$scratch/vips-8.18.7" --prefix "$toolchain/vips" --libdir lib \
  --buildtype release --auto-features disabled -Djpeg=enabled -Dpng=enabled -Dexif=enabled -Dlcms=enabled \
  -Dzlib=enabled -Ddeprecated=false -Dexamples=false -Dcplusplus=false -Dnsgif=false -Dppm=true -Danalyze=false -Dradiance=true
meson compile -C "$scratch/vips-build" -j 4
meson install -C "$scratch/vips-build"

mkdir "$toolchain/lib"
ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 "$toolchain/lib/libaio.so.1"
export RAILPRESS_PG_BIN="$toolchain/postgresql/bin"
export RAILPRESS_MYSQL_HOME="$toolchain/mysql-8.4.13-linux-glibc2.28-x86_64-minimal"
export RAILPRESS_NGINX_BIN="$toolchain/nginx/usr/sbin/nginx"
export RAILPRESS_WEBP_DECODER="$toolchain/libwebp-1.6.0-linux-x86-64/bin/dwebp"
export LD_LIBRARY_PATH="$toolchain/lib:$toolchain/vips/lib:$toolchain/postgresql/lib:$RAILPRESS_MYSQL_HOME/lib"
export PATH="$toolchain/ruby/bin:$RAILPRESS_PG_BIN:$PATH"
export BUNDLE_FROZEN=true
export BUNDLE_BUILD__PG="--with-pg-config=$RAILPRESS_PG_BIN/pg_config"
export BUNDLE_BUILD__MYSQL2="--with-mysql-config=$RAILPRESS_MYSQL_HOME/bin/mysql_config"
export BUNDLE_BUILD__FFI="--with-ldflags=-Wl,-rpath=$toolchain/vips/lib"
gem install --local --no-document "$scratch/bundler-4.0.24.gem"
bash scripts/native/bootstrap.sh
[[ "$("$RAILPRESS_WEBP_DECODER" -version)" == 1.6.0 ]]
"$RAILPRESS_NGINX_BIN" -v
bundle exec ruby -rpg -rmysql2 -rvips -e '
  abort "Incorrect PostgreSQL client ABI" unless PG.library_version == 160016
  abort "Incorrect MySQL client ABI" unless Mysql2::Client.info[:version] == "8.4.13"
  abort "Incorrect libvips runtime" unless Vips.version_string == "8.18.7"
  puts "Verified native PostgreSQL 16.16, MySQL 8.4.13 and libvips 8.18.7 linkage"
'
printf '%s\n' "$toolchain/ruby/bin" "$RAILPRESS_PG_BIN" >> "$GITHUB_PATH"
for key in RAILPRESS_PG_BIN RAILPRESS_MYSQL_HOME RAILPRESS_NGINX_BIN RAILPRESS_WEBP_DECODER LD_LIBRARY_PATH BUNDLE_FROZEN; do
  printf '%s=%s\n' "$key" "${!key}" >> "$GITHUB_ENV"
done
