#!/usr/bin/env bash
#
# Builds nginx-admin with the toolchain the project actually requires.
#
# Arguments are passed straight through to Maven, so this behaves like `mvn`:
#   ./build.sh                          # clean install, tests skipped
#   ./build.sh clean install            # same, written out
#   ./build.sh test                     # run the unit tests
#   ./build.sh -pl nginx-admin-ui -am install
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JDK8_HOME="${NGINX_ADMIN_JDK8_HOME:-/opt/jdk8}"
MAVEN_HOME="${NGINX_ADMIN_MAVEN_HOME:-/opt/apache-maven-3.5.4}"

if [ ! -x "$JDK8_HOME/bin/javac" ]; then
	echo "JDK 8 not found at $JDK8_HOME. Run ./.cursor/install.sh first." >&2
	exit 1
fi

if [ ! -x "$MAVEN_HOME/bin/mvn" ]; then
	echo "Maven not found at $MAVEN_HOME. Run ./.cursor/install.sh first." >&2
	exit 1
fi

export JAVA_HOME="$JDK8_HOME"
export PATH="$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH"

if [ "$#" -eq 0 ]; then
	set -- clean install -DskipTests
fi

exec mvn -B -s "$REPO_ROOT/.cursor/maven-settings.xml" "$@"
