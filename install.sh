#!/usr/bin/env bash
set -e

dc="docker-compose --no-ansi"
dcr="$dc run --rm"

# Thanks to https://unix.stackexchange.com/a/145654/108960
log_file="sentry_install_log-`date +'%Y-%m-%d_%H-%M-%S'`.txt"
exec &> >(tee -a "$log_file")

MIN_DOCKER_VERSION='17.05.0'
MIN_COMPOSE_VERSION='1.23.0'
MIN_RAM=2400 # MB

SENTRY_CONFIG_PY='sentry/sentry.conf.py'
SENTRY_CONFIG_YML='sentry/config.yml'
SENTRY_EXTRA_REQUIREMENTS='sentry/requirements.txt'

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [ "$DID_CLEAN_UP" -eq 1 ]; then
    return 0;
  fi
  echo "Cleaning up..."
  $dc stop &> /dev/null
  DID_CLEAN_UP=1
}
trap cleanup ERR INT TERM

echo "Checking minimum requirements..."

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
COMPOSE_VERSION=$($dc --version | sed 's/docker-compose version \(.\{1,\}\),.*/\1/')
RAM_AVAILABLE_IN_DOCKER=$(docker run --rm busybox free -m 2>/dev/null | awk '/Mem/ {print $2}');

# Compare dot-separated strings - function below is inspired by https://stackoverflow.com/a/37939589/808368
function ver () { echo "$@" | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }'; }

# Thanks to https://stackoverflow.com/a/25123013/90297 for the quick `sed` pattern
function ensure_file_from_example {
  if [ -f "$1" ]; then
    echo "$1 already exists, skipped creation."
  else
    echo "Creating $1..."
    cp -n $(echo "$1" | sed 's/\.[^.]*$/.example&/') "$1"
  fi
}

if [ $(ver $DOCKER_VERSION) -lt $(ver $MIN_DOCKER_VERSION) ]; then
    echo "FAIL: Expected minimum Docker version to be $MIN_DOCKER_VERSION but found $DOCKER_VERSION"
    exit 1
fi

if [ $(ver $COMPOSE_VERSION) -lt $(ver $MIN_COMPOSE_VERSION) ]; then
    echo "FAIL: Expected minimum docker-compose version to be $MIN_COMPOSE_VERSION but found $COMPOSE_VERSION"
    exit 1
fi

if [ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_RAM" ]; then
    echo "FAIL: Expected minimum RAM available to Docker to be $MIN_RAM MB but found $RAM_AVAILABLE_IN_DOCKER MB"
    exit 1
fi

#SSE4.2 required by Clickhouse (https://clickhouse.yandex/docs/en/operations/requirements/)
SUPPORTS_SSE42=$(docker run --rm busybox grep -c sse4_2 /proc/cpuinfo || :);
if (($SUPPORTS_SSE42 == 0)); then
    echo "FAIL: The CPU your machine is running on does not support the SSE 4.2 instruction set, which is required for one of the services Sentry uses (Clickhouse). See https://git.io/JvLDt for more info."
    exit 1
fi

# Clean up old stuff and ensure nothing is working while we install/update
# This is for older versions of on-premise:
$dc -p onpremise down --rmi local --remove-orphans
# This is for newer versions
$dc down --rmi local --remove-orphans

echo ""
echo "Creating volumes for persistent storage..."
echo "Created $(docker volume create --name=sentry-data)."
echo "Created $(docker volume create --name=sentry-redis)."
echo "Created $(docker volume create --name=sentry-zookeeper)."
echo "Created $(docker volume create --name=sentry-kafka)."
echo "Created $(docker volume create --name=sentry-clickhouse)."
echo "Created $(docker volume create --name=sentry-symbolicator)."

echo ""
ensure_file_from_example $SENTRY_CONFIG_PY
ensure_file_from_example $SENTRY_CONFIG_YML
ensure_file_from_example $SENTRY_EXTRA_REQUIREMENTS

echo ""
echo "Building and tagging Docker images..."
echo ""
# Build the sentry onpremise image first as it is needed for the cron image
$dc pull --ignore-pull-failures
docker pull ${SENTRY_IMAGE:-getsentry/sentry:latest}
$dc build --force-rm web
$dc build --force-rm --parallel
echo ""
echo "Docker images built."

echo "Bootstrapping Snuba..."
# `bootstrap` is for fresh installs, and `migrate` is for existing installs
# Running them both for both cases is harmless so we blindly run them
$dcr snuba-api bootstrap --force
$dcr snuba-api migrate
echo ""

echo ""
echo "Setting up database..."
$dcr web upgrade --noinput


SENTRY_DATA_NEEDS_MIGRATION=$(docker run --rm -v sentry-data:/data alpine ash -c "[ ! -d '/data/files' ] && ls -A1x /data | wc -l || true")
if [ "$SENTRY_DATA_NEEDS_MIGRATION" ]; then
  echo "Migrating file storage..."
  # Use the web (Sentry) image so the file owners are kept as sentry:sentry
  # The `\"` escape pattern is to make this compatible w/ Git Bash on Windows. See #329.
  $dcr --entrypoint \"/bin/bash\" web -c \
    "mkdir -p /tmp/files; mv /data/* /tmp/files/; mv /tmp/files /data/files; chown -R sentry:sentry /data"
fi

cleanup

echo ""
echo "----------------"
echo "You're all done! Run the following command to get Sentry running:"
echo ""
echo "  docker-compose up -d"
echo ""
