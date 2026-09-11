# Jenkins Docker Image

A Jenkins controller image based on `jenkins/jenkins:jdk21` (Debian 13 "trixie"),
extended with the tooling our pipelines need: Kubernetes deployment, SOPS/age
secret decryption, and headless browser testing.

## Contents

| Tool           | Version         | Source                                    |
| -------------- | --------------- | ----------------------------------------- |
| `kubectl`      | pinned to 1.33  | Official Kubernetes APT repo (GPG-signed) |
| `age`          | Debian trixie   | Debian archive (GPG-signed)               |
| `sops`         | latest release  | GitHub, verified with cosign + checksum   |
| `chromium`     | Debian trixie   | Debian archive (GPG-signed)               |
| `jq`, `rsync`, `gettext-base`, `xvfb`, `curl` | Debian trixie | Debian archive |

Docker CLI access is provided by mounting the host's Docker socket (see below).

The image is ~1.5GB, down from ~3.1GB previously: the Rust toolchain was removed
(it was installed as `root`, so it was never on the `jenkins` user's `PATH` and
therefore unusable), `--no-install-recommends` is used where safe, and APT lists
are cleaned in the same layer that creates them.

## Binary verification

Every binary in this image is verified at build time. Nothing is fetched
unverified, and any verification failure aborts the build.

**APT-sourced tools** (`kubectl`, `age`, `chromium`, and the utilities) are
verified by APT against a signed repository. For `kubectl` the Kubernetes
release key is fetched and dearmored in the builder stage, and the repository is
registered with `signed-by=`, so an unsigned or mis-signed package cannot
install.

**`sops`** is not packaged by Debian, so it is downloaded from GitHub. Its
version floats — the latest release is resolved from the HTTP redirect on
`https://github.com/getsops/sops/releases/latest` (deliberately not the GitHub
API, which is rate-limited for unauthenticated callers on GitHub-hosted
runners). Because the version is not pinned, a hardcoded checksum is impossible,
so trust comes from Sigstore instead:

1. `cosign verify-blob` checks the release's `checksums.sigstore.json` against a
   pinned certificate identity — the getsops `release.yml` workflow — and the
   GitHub Actions OIDC issuer. This proves the checksum file was produced by
   getsops' own CI and not by someone who merely has write access to the release
   page.
2. `sha256sum -c` then binds the downloaded binary to that verified checksum.

**`cosign` itself is the root of trust**, so it is pinned to an exact version
and SHA256 in the Dockerfile. Without this the chain would be circular: anyone
able to substitute the `sops` binary could substitute the `cosign` that checks
it. Both `COSIGN_VERSION` and `COSIGN_SHA256` must be updated together, from
`cosign_checksums.txt` on the [cosign releases page](https://github.com/sigstore/cosign/releases).

A multi-stage build keeps `cosign`, `gnupg`, and the download tooling out of the
final image; only the verified `sops` binary and the dearmored APT keyring are
copied across.

Finally, a smoke test runs as the `jenkins` user at the end of the build and
executes every tool. A tool that is missing, unreadable, or not on the `jenkins`
user's `PATH` fails the build rather than a pipeline at 2am.

## Maintenance

Most updates are automatic. The nightly workflow rebuilds when the upstream
Jenkins image changes, which picks up Debian and Kubernetes patch releases at
the same time. Three things need a human:

- **`COSIGN_VERSION` / `COSIGN_SHA256`** — bump together, occasionally. A stale
  cosign is low-risk since its verification semantics are stable.
- **`KUBERNETES_MINOR`** — must track the cluster. `kubectl` supports ±1 minor
  from the API server; it is currently pinned to `v1.33` to match our RKE2
  cluster. **Update this when the cluster is upgraded.**
- **A `sops` major version bump.** Because the `sops` version floats without an
  upper bound, a future sops 4.0 will enter the image on a nightly rebuild with
  no build-time warning, potentially changing config or key semantics. If sops
  behaviour changes unexpectedly, check `sops --version` in the image first.

There is deliberately no Renovate or Dependabot configuration. (Note that
Dependabot could not maintain these values anyway — it only updates `FROM`
image references, not versions held in `ARG`s.)

## Build arguments

| Argument           | Default   | Purpose                             |
| ------------------ | --------- | ----------------------------------- |
| `DOCKER_GID`       | `988`     | GID of the host's `docker` group    |
| `KUBERNETES_MINOR` | `v1.33`   | Kubernetes APT repo minor version   |
| `COSIGN_VERSION`   | `v3.1.3`  | Pinned cosign version               |
| `COSIGN_SHA256`    | (pinned)  | Pinned cosign checksum              |

### Docker group ID

The image creates a `docker` group at GID `988` and adds `jenkins` to it, so the
mounted Docker socket is usable. **This GID must match the host's.** Check with:

```bash
getent group docker
```

If it differs, either rebuild:

```bash
docker build --build-arg DOCKER_GID=$(getent group docker | cut -d: -f3) -t jenkins-docker .
```

or override at runtime with `--group-add $(getent group docker | cut -d: -f3)`.

## Usage

```bash
docker build -t jenkins-docker .

docker run -d \
  --name jenkins \
  -p 8080:8080 \
  -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-docker
```

## Environment variables

- `CHROME_BIN` — set to `/usr/bin/chromium` for headless browser testing.
  Chromium is installed *with* its recommended packages, because those include
  the font packages headless rendering needs; without them, screenshots and PDFs
  silently render tofu boxes instead of text.

## Security considerations

Two properties of this setup are worth being explicit about, because both are
larger risks than anything the binary verification above addresses.

**This image runs jobs on the controller.** It is a Jenkins controller image,
but it also carries build tooling (chromium, kubectl, rsync, xvfb) and executes
pipelines on the built-in node. Controller and agent therefore share a trust
boundary: any job can read `JENKINS_HOME`, which includes credentials,
decryption keys, and job configuration. A compromised or malicious pipeline
compromises the whole Jenkins instance. Running builds on separate agents is the
standard mitigation, and would be the single highest-value hardening change to
this setup.

**The Docker socket grants root on the host.** A mounted `/var/run/docker.sock`
lets any process in the container start a privileged container mounting the host
filesystem. Combined with the point above, this means any pipeline that can run
on this Jenkins effectively has root on the Docker host. Only run trusted
pipelines here, and treat the ability to configure a job as equivalent to
granting host root.

The build tooling itself has a much better story: every binary is verified
against a signature or a signed repository, no `curl | bash` remains in the
build, and verification failures are hard build errors.

## Architecture

`linux/amd64` only. The tools all ship arm64 builds, but the image is neither
built nor tested for it.
