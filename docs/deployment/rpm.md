# RPM install (Fedora 43, PostgreSQL 18)

The alpha release provides a native RPM for Fedora 43 and PostgreSQL 18. Download the release asset or build the same package from a committed checkout on Fedora 43. The package contains `allgres.so`, extension control and SQL files, the license, and operator documentation. It does not include database data or provider keys.

## Download and install

```bash
curl -fL -O https://github.com/allgres/allgres-agent/releases/download/v0.1.0-alpha.1/allgres-0.1.0-0.alpha.1.fc43.x86_64.rpm
sudo dnf install ./allgres-0.1.0-0.alpha.1.fc43.x86_64.rpm
```

This package targets Fedora 43 on x86_64. Use the source build below for another architecture or when changing the extension.

## Build and inspect

```bash
git clone https://github.com/allgres/allgres-agent.git
cd allgres-agent
sh packaging/rpm/verify-fedora.sh
rpm_topdir="$(rpm --eval '%{_topdir}')"
find "$rpm_topdir/RPMS" -type f -name 'allgres-*.rpm' -print
```

The script installs build dependencies, creates a source archive from committed files, runs `rpmbuild` and `rpmlint`, and checks that the extension files are present. It targets Fedora 43's PostgreSQL 18 packaging. `pgcrypto` and `pgvector` remain optional; install the matching PostgreSQL packages if you need those features.

## Install the locally built RPM

```bash
rpm_topdir="$(rpm --eval '%{_topdir}')"
sudo dnf install "$rpm_topdir"/RPMS/*/allgres-[0-9]*.rpm
```

Set `shared_preload_libraries = 'allgres'` in the server's `postgresql.conf`, restart PostgreSQL, then create the extension in each database that will use it:

```bash
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS allgres;'
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 \
  -c 'SELECT allgres_public.fn_selftest();'
```

Use `SHOW config_file;` in `psql` to locate the active configuration file and your distribution's PostgreSQL service to restart it. The dashboard listens on `127.0.0.1:8088` by default. Follow the [source install guide](source-install.md) for first-admin setup, PostgreSQL service environment variables, and verification, and the [security model](../security.md) before exposing the dashboard.

The RPM build and lint are configured in CI and run again on an alpha tag before its RPM is attached to the release. A local Fedora 43 container build passed `rpmlint` with no errors or warnings, and the package installed with `dnf`. A PostgreSQL runtime smoke test using the installed RPM remains open; check [open alpha readiness](../open-alpha-readiness.md) for the current status.
