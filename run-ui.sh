#!/usr/bin/env bash
#
# Runs the nginx-admin manager UI from the locally built uber-jar.
#
# Listens on http://localhost:4000 (and https://localhost:4443) and stores its
# H2 database under the runtime directory, so nothing outside that directory is
# modified. Default credentials are admin / admin.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${NGINX_ADMIN_RUNTIME_DIR:-/tmp/nginx-admin-runtime}"
JDK8_HOME="${NGINX_ADMIN_JDK8_HOME:-/opt/jdk8}"

TARGET_DIR="$REPO_ROOT/nginx-admin-ui-standalone/target"
CONF_TEMPLATE="$REPO_ROOT/nginx-admin-ui-standalone/nginx-admin/conf/nginx-admin.conf"

find_swarm_jar() {
	find "$TARGET_DIR" -maxdepth 1 -name 'nginx-admin-ui-standalone-*-swarm.jar' 2>/dev/null | head -1
}

SWARM_JAR="$(find_swarm_jar)"
if [ -z "$SWARM_JAR" ]; then
	echo "[run-ui] uber-jar not built yet, building now"
	"$REPO_ROOT/build.sh"
	SWARM_JAR="$(find_swarm_jar)"
fi

if [ -z "$SWARM_JAR" ]; then
	echo "[run-ui] build completed but no swarm jar was produced in $TARGET_DIR" >&2
	exit 1
fi

mkdir -p "$RUNTIME_DIR/conf" "$RUNTIME_DIR/database" "$RUNTIME_DIR/log"

# The packaged conf uses shell-style $NGINX_ADMIN_HOME references and an
# /opt install prefix, but it is read as a plain java.util.Properties file.
# Rewrite the paths that must be absolute and writable.
sed \
	-e "s#^NGINX_ADMIN_HOME=.*#NGINX_ADMIN_HOME=$RUNTIME_DIR#" \
	-e "s#^NGINX_ADMIN_BIN=.*#NGINX_ADMIN_BIN=$RUNTIME_DIR/bin#" \
	-e "s#^NGINX_ADMIN_LOG=.*#NGINX_ADMIN_LOG=$RUNTIME_DIR/log#" \
	-e "s#^NGINX_ADMIN_CONF=.*#NGINX_ADMIN_CONF=$RUNTIME_DIR/conf#" \
	-e "s#^NGINX_ADMIN_DB_LOCATION=.*#NGINX_ADMIN_DB_LOCATION=$RUNTIME_DIR/database#" \
	"$CONF_TEMPLATE" > "$RUNTIME_DIR/conf/nginx-admin.conf"

# H2 refuses to start against a stale lock left behind by a killed process.
rm -f "$RUNTIME_DIR"/database/*.lock.db

echo "[run-ui] starting $(basename "$SWARM_JAR") on http://localhost:4000"

exec "$JDK8_HOME/bin/java" \
	-server \
	-Djava.net.preferIPv4Stack=true \
	-Djava.awt.headless=true \
	-Xms256m -Xmx1g \
	-jar "$SWARM_JAR" \
	-c "$RUNTIME_DIR/conf/nginx-admin.conf"
