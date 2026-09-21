# RPM install (Fedora 43, PostgreSQL 18)

The public alpha includes a native RPM spec, not a prebuilt downloadable RPM. Build it from a committed checkout on Fedora 43, then install it into the same PostgreSQL 18 package family used to build it. The package contains `allgres.so`, extension control and SQL files, the license, and operator documentation. It does not include database data or provider keys.

## Build and inspect

```bash
git clone https://github.com/allgres/allgres-agent.git
cd allgres-agent
sh packaging/rpm/verify-fedora.sh
rpm_topdir="$(rpm --eval '%{_topdir}')"
find "$rpm_topdir/RPMS" -type f -name 'allgres-*.rpm' -print
```

The script installs build dependencies, creates a source archive from committed files, runs `rpmbuild` and `rpmlint`, and checks that the extension files are present. It targets Fedora 43's PostgreSQL 18 packaging. `pgcrypto` and `pgvector` remain optional; install the matching PostgreSQL packages if you need those features.

## Install into an existing PostgreSQL 18 server

```bash
rpm_topdir="$(rpm --eval '%{_topdir}')"
sudo dnf install "$rpm_topdir"/RPMS/*/allgres-*.rpm
```

Set `shared_preload_libraries = 'allgres'` in the server's `postgresql.conf`, restart PostgreSQL, then create the extension in each database that will use it:

```bash
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS allgres;'
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 \
  -c 'SELECT allgres_public.fn_selftest();'
```

Use `SHOW config_file;` in `psql` to locate the active configuration file and your distribution's PostgreSQL service to restart it. The dashboard listens on `127.0.0.1:8088` by default. Follow the [source install guide](source-install.md) for first-admin setup, PostgreSQL service environment variables, and verification, and the [security model](../security.md) before exposing the dashboard.

The RPM build and lint are configured in CI. A fresh installation and runtime smoke test of the RPM remain an open release gate; check [open alpha readiness](../open-alpha-readiness.md) for the current status. Release publication is separate from this source-built path.
