# 8. Releasing

For maintainers of this repo. Everything else in `docs/` is about *consuming*
what a release produces.

---

## What a release produces

Pushing a `vX.Y.Z` tag runs [`.github/workflows/release.yml`](../.github/workflows/release.yml),
which publishes seven things and cuts a GitHub Release:

| | |
| --- | --- |
| `oci://ghcr.io/crunchymonkies/charts/headroom:X.Y.Z` | chart |
| `oci://ghcr.io/crunchymonkies/charts/ix:X.Y.Z` | chart |
| `oci://ghcr.io/crunchymonkies/charts/workgroup:X.Y.Z` | umbrella, with both subcharts vendored in |
| `ghcr.io/crunchymonkies/headroom:X.Y.Z` | patched Headroom image |
| `ghcr.io/crunchymonkies/headroom:<upstream-short-sha>-neo4j` | same image, named by what it actually is |
| `ghcr.io/crunchymonkies/headroom:latest` | same image |
| Release `vX.Y.Z` | the three `.tgz`, `install.sh`, `install.ps1`, `SHA256SUMS` |

The charts are OCI artefacts only — there is no `helm repo add` index to
maintain.

---

## Chart.yaml is the source of truth

The version is **not** rewritten in CI. `charts/workgroup` pins its two
subcharts by exact version, so rewriting versions at package time would leave
the umbrella pointing at versions that were never published.

Instead, a release is a reviewable commit that bumps four fields, and CI asserts
the tag agrees with them:

| File | Field |
| --- | --- |
| `charts/headroom/Chart.yaml` | `version`, and `appVersion` to match |
| `charts/ix/Chart.yaml` | `version` |
| `charts/workgroup/Chart.yaml` | `version` |
| `charts/workgroup/Chart.yaml` | both `dependencies[].version` |

`charts/headroom`'s `appVersion` is load-bearing: `image.tag` defaults to `""`,
which resolves to `.Chart.AppVersion`, which is the tag the release workflow
gives the image. Keeping `appVersion == version` is what makes a chart and its
image ship together.

`charts/ix` keeps `appVersion: latest` — this repo does not rebuild the Ix
memory-layer image, it consumes upstream's.

Check it locally before tagging:

```sh
scripts/verify-versions.sh v0.2.0
```

---

## Cutting a release

```sh
# 1. Bump the four fields above, then confirm they agree with the tag you mean
#    to push.
scripts/verify-versions.sh v0.2.0

# 2. Run the same checks CI will run.
scripts/verify-charts.sh all     # lint, render matrix, guard rails, schema
scripts/verify-patch.sh          # the patch still applies upstream (network)
scripts/verify-doc-links.sh
shellcheck install.sh scripts/*.sh
pwsh -c 'Invoke-ScriptAnalyzer -Path ./install.ps1 -Severity Error'

# 3. Commit, then tag.
git commit -am "release: v0.2.0"
git push
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

The tag must be an annotated or signed tag — the release step passes
`--verify-tag`.

### Rehearsing first

`workflow_dispatch` on the Release workflow builds and verifies everything and
publishes nothing:

```sh
gh workflow run release.yml -f dry_run=true
```

It takes the version from `charts/workgroup/Chart.yaml` instead of a tag. Worth
doing after any change to the patch, the Dockerfile's upstream, or the workflow
itself.

---

## What the workflow checks before it publishes

In order, because the ordering is the safety property:

1. **`verify`** — `verify-versions.sh` (tag ⇔ Chart.yaml), `verify-charts.sh all`
   (every render, every guard rail), `verify-patch.sh` (the patch still applies
   to the pinned upstream commit).
2. **`image`** — checks out upstream at `HEADROOM_BASE_COMMIT`, applies the
   patch (**hard failure**, never an unpatched fallback), builds locally, and
   then asserts the patch is live *in the artefact*:

   ```sh
   docker run --rm headroom-verify:local --help   # ENTRYPOINT is ["headroom","proxy"]
   ```

   All four of `--memory-backend`, `--memory-neo4j-uri`, `--memory-neo4j-user`
   and `--memory-neo4j-password` must appear. Only then does it push.
3. **`charts`** — runs *after* `image`, so a published chart can never reference
   an image tag that does not exist. Packages, pushes, then pulls the umbrella
   back out of the registry and renders it as a round-trip check.
4. **`release`** — only on a tag push. Assembles the assets, generates
   `SHA256SUMS`, writes the notes, `gh release create`.

The image is built for `linux/amd64` only (`IMAGE_PLATFORMS` at the top of the
workflow). arm64 needs QEMU emulation and this image compiles Python ML wheels,
which takes the better part of an hour emulated. To add it: append the platform
and add `docker/setup-qemu-action` before the build steps.

---

## Re-basing the patch onto a newer upstream

The patch is pinned to one upstream commit in
[`patches/upstream.env`](../patches/upstream.env), which is the only place that
commit appears.

```sh
# 1. Point at the new commit.
$EDITOR patches/upstream.env      # HEADROOM_BASE_COMMIT=<new sha>

# 2. Does it still apply?
scripts/verify-patch.sh
```

If it does, that one-line change is the whole re-base. If it does not:

```sh
scripts/verify-patch.sh --keep    # leaves a checkout of the new commit
```

Re-apply the three changes by hand in that tree — `headroom/memory/neo4j_env.py`,
`headroom/proxy/models.py`, `headroom/cli/proxy.py`; see
[patches/README.md](../patches/README.md) for what each one does — then
regenerate:

```sh
git -C <tree> diff > patches/0001-headroom-neo4j-config-surface.patch
scripts/verify-patch.sh
```

Then cut a release: the image tag `<upstream-short-sha>-neo4j` changes with the
base commit, so the new base is visible in the registry without reading any
metadata.

**If upstream merges the patch**, delete it, drop the guard's denylist entry in
`charts/headroom/templates/_helpers.tpl`, and point `image.repository` back at
upstream in `charts/headroom/values.yaml`. Until then, consumers who want the
stock image can set `memory.acknowledgeUnpatchedImage: true`.

---

## Recovering a failed release

**The tag pushed but the workflow failed.** Nothing was published if it failed
in `verify` or `image` — those run before any push. Fix, then re-run the failed
jobs from the Actions UI; the tag does not need to move.

**Some artefacts published, some did not.** The steps are idempotent except the
last: `helm push` overwrites a tag, `docker push` overwrites a tag, but
`gh release create` fails if the release already exists. Delete the release
(`gh release delete vX.Y.Z`, keeping the tag) and re-run.

**The release is wrong and people have it.** Do not move the tag — a moved tag
means two different artefacts with one name, and the OCI charts and the image
would then disagree with the Release assets. Cut `vX.Y.Z+1` and mark the bad
release as a pre-release with a note. GHCR versions can be deleted from the
package settings if the artefact is actively harmful.

**The image published but the chart did not.** Harmless: the chart is what
points at the image, and nothing references an unpublished chart. Re-run the
`charts` job.

---

## Repository settings this expects

- **Actions → General → Workflow permissions**: read-only by default. Each job
  requests what it needs (`packages: write`, `contents: write`,
  `attestations: write`), so no repo-wide escalation is required.
- **Branch protection on `main`**: require the `CI Passed` check. It is a single
  aggregate context, so the job graph can be reshaped without re-configuring
  the required check.
- **Package visibility**: the first `helm push` / `docker push` creates the
  package as private. Make `charts/*` and `headroom` public in the package
  settings, or consumers need a token to `helm install`.

  There is no API for this — it is a UI-only setting, at
  `github.com/orgs/<org>/packages` → the package → *Package settings* →
  *Change visibility*. So the first release of any new chart will always
  publish it private; the `Anonymous pull works` step in the release workflow
  warns when that is still the case, which is why it is `continue-on-error`.

---

## Verifying a release as a consumer

```sh
# What the image actually is, without trusting the tag name.
docker inspect ghcr.io/crunchymonkies/headroom:0.2.0 \
  --format '{{json .Config.Labels}}' | jq

# The release assets.
sha256sum -c SHA256SUMS

# The image's build provenance, keyless-signed and bound to the digest.
gh attestation verify oci://ghcr.io/crunchymonkies/headroom:0.2.0 \
  -R CrunchyMonkies/headroom-for-workgroups
```

The `io.headroom-for-workgroups.upstream.commit` and `.patch.sha256` labels name
exactly which upstream commit and which patch content went into the image. They
are always present, which is why they come first.

`gh attestation verify` is the stronger check but is not always available:
`actions/attest-build-provenance` requires a paid GitHub plan on a **private**
repository. This repo is private on a free org, so the release workflow marks
that step `continue-on-error` and a release may legitimately ship without an
attestation. `gh attestation verify` then reports no attestation found — which
means "none was produced", not "the image was tampered with". Drop the
`continue-on-error` in `release.yml` if the repo goes public or the plan
changes.
