#!/usr/bin/env bash
#
# Provisions the toolchain nginx-admin needs and warms the local Maven
# repository by running a full reactor build. Safe to re-run.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# nginx-admin targets Java 8 and wildfly-swarm 2017.11.0. The swarm packaging
# plugin is built against the Maven 3.5 Aether API and throws AbstractMethodError
# under Maven 3.8+, so both the JDK and Maven are pinned to that era.
JDK8_VERSION="8u504-b01"
JDK8_URL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk${JDK8_VERSION}/OpenJDK8U-jdk_x64_linux_hotspot_8u504b01.tar.gz"
JDK8_SHA256="9c70e102f527ac674ac2fe9c7d47b9a04e2d19842ba5ab8e9b33f368bbadfaea"

MAVEN_VERSION="3.5.4"
MAVEN_URL="https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
MAVEN_SHA512="2a803f578f341e164f6753e410413d16ab60fabe31dc491d1fe35c984a5cce696bc71f57757d4538fe7738be04065a216f3ebad4ef7e0ce1bb4c51bc36d6be86"

JDK8_HOME="/opt/jdk8"
MAVEN_HOME="/opt/apache-maven-${MAVEN_VERSION}"

log() { printf '[install] %s\n' "$*"; }

# Downloads to $1 from $2 and aborts unless it hashes to $4 under algorithm $3.
fetch_verified() {
	local dest="$1" url="$2" algo="$3" expected="$4" actual
	curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
	actual="$("${algo}sum" "$dest" | awk '{print $1}')"
	if [ "$actual" != "$expected" ]; then
		echo "[install] checksum mismatch for $url" >&2
		echo "[install]   expected: $expected" >&2
		echo "[install]   actual:   $actual" >&2
		rm -f "$dest"
		return 1
	fi
}

install_jdk8() {
	if [ -x "$JDK8_HOME/bin/javac" ]; then
		log "JDK 8 already present at $JDK8_HOME"
		return
	fi
	log "installing Temurin JDK ${JDK8_VERSION}"
	local tmp
	tmp="$(mktemp -d)"
	fetch_verified "$tmp/jdk8.tar.gz" "$JDK8_URL" sha256 "$JDK8_SHA256"
	sudo mkdir -p "$JDK8_HOME"
	sudo tar -xzf "$tmp/jdk8.tar.gz" -C "$JDK8_HOME" --strip-components=1
	rm -rf "$tmp"
}

install_maven() {
	if [ -x "$MAVEN_HOME/bin/mvn" ]; then
		log "Maven ${MAVEN_VERSION} already present at $MAVEN_HOME"
		return
	fi
	log "installing Maven ${MAVEN_VERSION}"
	local tmp
	tmp="$(mktemp -d)"
	fetch_verified "$tmp/maven.tar.gz" "$MAVEN_URL" sha512 "$MAVEN_SHA512"
	sudo tar -xzf "$tmp/maven.tar.gz" -C /opt
	rm -rf "$tmp"
}

# Makes `java`/`mvn` resolve to the pinned toolchain in interactive shells.
# build.sh does not rely on this; it sets the same values itself.
install_profile() {
	log "writing /etc/profile.d/nginx-admin-toolchain.sh"
	sudo tee /etc/profile.d/nginx-admin-toolchain.sh >/dev/null <<EOF
export JAVA_HOME="$JDK8_HOME"
export M2_HOME="$MAVEN_HOME"
export PATH="\$JAVA_HOME/bin:\$M2_HOME/bin:\$PATH"
EOF
	sudo chmod 0644 /etc/profile.d/nginx-admin-toolchain.sh
}

# Only seeds the user-level settings when there is nothing to clobber. build.sh
# always passes .cursor/maven-settings.xml explicitly, so this is convenience
# for anyone invoking `mvn` directly.
install_maven_settings() {
	local user_settings="$HOME/.m2/settings.xml"
	mkdir -p "$HOME/.m2"
	if [ -e "$user_settings" ]; then
		log "leaving existing $user_settings untouched"
		return
	fi
	log "seeding $user_settings"
	cp "$REPO_ROOT/.cursor/maven-settings.xml" "$user_settings"
}

install_jdk8
install_maven
install_profile
install_maven_settings

log "running full reactor build to warm ~/.m2 and verify the toolchain"
"$REPO_ROOT/build.sh" clean install -DskipTests

log "done"
