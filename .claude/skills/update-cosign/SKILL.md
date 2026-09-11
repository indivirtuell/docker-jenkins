---
name: update-cosign
description: Bump the pinned cosign version and checksum in the Dockerfile.
disable-model-invocation: true
---

# Update cosign

`cosign` is the root of trust for the `sops` install: it verifies the Sigstore
bundle that in turn verifies the sops binary. It is therefore pinned in the
Dockerfile by both `COSIGN_VERSION` and `COSIGN_SHA256`, which **always move
together** — a version bumped without its checksum fails the build, and a
checksum bumped without its version pins the wrong binary.

Trust the *currently pinned* cosign to verify its replacement. Downloading a new
cosign and taking its checksum from the same page you downloaded it from proves
nothing; the old binary is the only trusted thing on hand, so use it.

## Steps

1. **Resolve the target version.** Latest is the default:

   ```bash
   curl -fsSI https://github.com/sigstore/cosign/releases/latest | tr -d '\r' \
     | sed -n 's#^location:.*/tag/\(v[^ ]*\)$#\1#Ip'
   ```

   If it already matches `COSIGN_VERSION` in the Dockerfile, report that cosign
   is current and stop.

2. **Build the currently trusted cosign** from the values in the Dockerfile
   right now, before changing anything. Download `cosign-linux-amd64` at the
   pinned `COSIGN_VERSION` and confirm it against the pinned `COSIGN_SHA256`
   with `sha256sum -c`. A mismatch here means the existing pin is wrong or
   upstream was altered — stop and report it rather than continuing.

3. **Verify the new binary with the old one.** Download the new
   `cosign-linux-amd64` and its `cosign-linux-amd64.sigstore.json`, then run the
   *old* cosign against it. cosign signs its own releases with a Google service
   account, not a GitHub Actions workflow, so the identity is:

   ```bash
   ./cosign-old verify-blob \
     --bundle cosign-linux-amd64.sigstore.json \
     --certificate-identity 'keyless@projectsigstore.iam.gserviceaccount.com' \
     --certificate-oidc-issuer 'https://accounts.google.com' \
     cosign-new
   ```

   Anything other than `Verified OK` ends the update. Report it and change
   nothing.

4. **Compute the new checksum** with `sha256sum` over the binary you just
   verified, and edit both `COSIGN_VERSION` and `COSIGN_SHA256` in the
   Dockerfile.

5. **Prove the pin.** Run `docker build --target builder -t cosign-check .` and
   confirm it succeeds — this re-downloads cosign from scratch and re-runs the
   whole sops verification chain against the new pin. Remove the test image
   afterwards. A build that fails on `sha256sum -c` means the checksum in the
   Dockerfile is wrong; fix it before reporting.

6. **Report** the old and new versions, and state that the new binary was
   signature-verified with the previously pinned cosign. Leave the change
   uncommitted unless asked.

## Release notes

Read the release notes between the old and new versions and mention anything
affecting `verify-blob`, bundle formats, or certificate identity flags — those
are the surfaces the Dockerfile depends on. A major version bump is worth
flagging explicitly, since cosign has changed `verify-blob` flag semantics
across majors before.
