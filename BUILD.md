# Building nginx-admin

## Quick start

```bash
./.cursor/install.sh     # one-time: provisions the toolchain, then builds everything
./build.sh               # subsequent builds (clean install, tests skipped)
./run-ui.sh              # run the manager UI on http://localhost:4000 (admin / admin)
```

`build.sh` forwards its arguments to Maven, so `./build.sh test`, `./build.sh -pl nginx-admin-ui -am install`
and similar all work.

## Why the toolchain is pinned

The project was last built in 2017/2018 against the toolchain of that era, and three
separate things break on a current toolchain. All three are environmental; none of
them require changing project code.

### 1. JDK 8 is required, not merely targeted

The POMs set `source`/`target` to 1.8, but the dependency on Java 8 is harder than
that. `nginx-admin-agent-model` imports `javax.xml.bind.annotation`, and JAXB was
removed from the JDK in Java 11. On JDK 21 the reactor fails on the third module:

```
package javax.xml.bind.annotation does not exist
```

The same applies to the rest of the Java EE 7 surface the project consumes from the
`javax:javaee-api:7.0` `provided` dependency. Moving off JDK 8 means adding the
standalone JAXB artifacts and, eventually, a `javax` to `jakarta` migration.

### 2. Maven must be 3.5.x

`wildfly-swarm-plugin:2017.11.0` is compiled against the Maven 3.3/3.5 Aether API.
Under Maven 3.8+ its packaging goal fails with:

```
An API incompatibility was encountered while executing
org.wildfly.swarm:wildfly-swarm-plugin:2017.11.0:package: java.lang.AbstractMethodError
```

This is narrower than it first appears. Under Maven 3.8.7 on JDK 8, the nine library
and WAR modules all build cleanly; only the two `*-standalone` uber-jar modules fail.
The Maven pin exists solely for the WildFly Swarm packaging step.

### 3. The iText dependency needs an HTTPS mirror

`jasperreports:6.4.0` pulls in `com.lowagie:itext:2.1.7.js5`, which is not on Maven
Central. It is only published in the Jaspersoft third-party repository, which
`jasperreports` declares over plain HTTP. Maven 3.8+ blocks HTTP repositories, so
resolution fails with `Blocked mirror for repositories: [jaspersoft-third-party ...]`.

That repository serves the same artifact over HTTPS, so
[`.cursor/maven-settings.xml`](.cursor/maven-settings.xml) mirrors it rather than
re-enabling plain HTTP. `build.sh` always passes that file with `-s`.

### Harmless warning

`com.jslsolucoes:ojdbc6:11.2.0.1.0` is published to Central as a jar with no POM, so
Maven logs "The POM for ... is missing, no dependency information available". The jar
resolves and the build succeeds.

## Tests

`./build.sh` skips tests by default, matching what `.travis.yml` did. There is one
test class in the whole reactor, `nginx-admin-database`'s `DatabaseMigrateTest`, and
both of its cases are integration tests with unguarded external dependencies:

- `migrateMySql` connects to a MySQL server on `localhost:3306` with database
  `migrate`. Without one it fails with `CommunicationsException`.
- `migrateH2` binds an H2 TCP server on the hardcoded port 9123, which is the same
  port `run-ui.sh` uses. It fails with `BindException` if the manager UI is running.

So `./build.sh test` is only meaningful with MySQL available and the UI stopped. There
is no unit-test coverage to speak of, which is worth knowing before relying on the
build as a regression signal.

## What gets produced

| Module | Artifact | Purpose |
| --- | --- | --- |
| `nginx-admin-ui-standalone` | `nginx-admin-ui-standalone-2.0.3-swarm.jar` (~162 MB) | Manager UI uber-jar; serves HTTP 4000 / HTTPS 4443 |
| `nginx-admin-ui-standalone` | `nginx-admin-2.0.3.zip` | Distribution: uber-jar plus conf and SysV init scripts |
| `nginx-admin-agent-standalone` | `nginx-admin-agent-standalone-2.0.3-swarm.jar` (~94 MB) | Agent uber-jar; serves HTTP 3000 / HTTPS 3443 |
| `nginx-admin-agent-standalone` | `nginx-admin-agent-2.0.3.zip` | Distribution for the agent |

The two zips are what `nginx-admin-docker/` builds its images from.

## Architecture in one paragraph

One manager UI talks to one agent per nginx host. The UI
(`nginx-admin-ui`, a WAR) is a VRaptor 4 MVC application rendering JSP through the
`tagria` tag library, persisting through JPA/Hibernate. The agent (`nginx-admin-agent`,
also a WAR) exposes a JAX-RS API that manipulates the local nginx installation, and the
UI reaches it through `nginx-admin-agent-client`. Both WARs are wrapped into
self-contained uber-jars by WildFly Swarm, which embeds Undertow, CDI, JPA and the
datasource subsystem. The UI supports H2 (default, embedded and auto-started),
PostgreSQL, MySQL, MariaDB, SQL Server and Oracle, and applies its own SQL migrations
from `nginx-admin-ui-standalone/src/main/resources/db/migration/` at startup.

## Running locally

`run-ui.sh` builds the uber-jar if it is missing, writes a runtime config with
absolute writable paths into `/tmp/nginx-admin-runtime` (override with
`NGINX_ADMIN_RUNTIME_DIR`), and starts the server. The packaged
`nginx-admin-ui-standalone/nginx-admin/conf/nginx-admin.conf` cannot be used directly
because it is read as a `java.util.Properties` file while containing shell-style
`$NGINX_ADMIN_HOME` references and an `/opt` install prefix.

On startup you should see the migrations apply and the WAR deploy:

```
DatabaseMigrationBuilder ... File v.2.0.0.sql was applyed successfully on database
DatabaseMigrationBuilder ... File v.2.0.1.sql was applyed successfully on database
WFSWARM99999: WildFly Swarm is Ready
```

Unauthenticated requests to `/` return HTTP 401 with the login page as the body; this
is the application's normal behaviour, not an error. Default credentials are
`admin` / `admin`, and the first sign-in redirects to `/user/changePassword` before it
will let you reach the dashboard.

## A separate latent problem: CRLF line endings

46 files are committed with CRLF, including the four
`nginx-admin-docker/release/*/build/install.sh` scripts. Those are `#!/bin/sh`
scripts meant to be executed directly, and a CRLF shebang makes the kernel look for
an interpreter whose name ends in `\r`, so they cannot run as committed. The
`fixcrlf` Ant tasks in the two `*-standalone` POMs exist to work around the same
issue for the packaged conf and scripts.

Normalising the repository would touch roughly 170 files, so it is deliberately out
of scope here; `.gitattributes` only pins the three scripts added alongside this
document. It is worth doing on its own.

## Modernising the build

The pinned toolchain above is the cheapest way to get a working build today and needs
no code changes. If the project needs to move forward, the ordering that matters is:

1. **Replace the packaging layer first.** WildFly Swarm is the single most expensive
   pin: it alone forces Maven 3.5. Swarm became Thorntail, which reached end of life in
   2022, so there is no in-place upgrade. Emitting plain WARs and deploying to a
   supported container removes the Maven constraint immediately and is a
   packaging-module-only change; the nine other modules already build under Maven 3.8.
2. **Then move off JDK 8.** This means adding explicit JAXB dependencies, and past
   WildFly 26.1 / Java EE 8, migrating the whole `javax.*` namespace to `jakarta.*`.
   That touches essentially every source file, though mechanically.
3. **The UI framework is the real cost.** VRaptor 4 has had no release since 2016 and
   the `tagria` JSP tag library is a first-party dependency of the same vintage. Any
   move to a supported stack (Quarkus, Spring Boot) is a rewrite of the presentation
   layer rather than a migration, so it should be scoped separately from steps 1 and 2
   and not treated as a prerequisite for them.

Steps 1 and 2 are independent of step 3: the build and runtime can be modernised while
the VRaptor UI is left in place.
