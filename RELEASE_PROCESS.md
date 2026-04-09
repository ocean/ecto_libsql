# Release Process

## 1. Prepare

Bump `@version` in `mix.exs`, update `CHANGELOG.md`, run tests, then commit and push to `main`:

```bash
# Confirm clean
mix test && cd native/ecto_libsql && cargo test && cd ../..
mix format --check-formatted && cd native/ecto_libsql && cargo fmt --check && cd ../..

git add mix.exs CHANGELOG.md
git commit -m "chore: bump version to X.Y.Z"
git push
```

## 2. Create the GitHub release (triggers CI)

The CI workflow triggers on tags matching `*.*.*`. The tag must match the version in `mix.exs` exactly — no `v` prefix, as the `base_url` in `native.ex` uses the raw version string.

```bash
gh release create X.Y.Z --title "vX.Y.Z" --draft --generate-notes
```

This creates the tag and a draft release. The CI workflow fires and builds all 6 NIF targets, uploading each artifact to the release.

## 3. Wait for all CI jobs to finish

```bash
gh run list --workflow=release.yml
```

All 6 matrix jobs must succeed:

- `aarch64-apple-darwin`, `x86_64-apple-darwin`
- `aarch64-unknown-linux-gnu`, `aarch64-unknown-linux-musl`
- `x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`

## 4. Regenerate the checksum file

Once all artifacts are uploaded to the release:

```bash
MIX_ENV=prod mix rustler_precompiled.download EctoLibSql.Native --all --ignore-unavailable
```

This downloads every artifact from the GitHub release and regenerates `checksum-Elixir.EctoLibSql.Native.exs`. Verify the file has all 6 entries with fresh sha256 hashes.

## 5. Commit and push the checksum

```bash
git add checksum-Elixir.EctoLibSql.Native.exs
git commit -m "chore: update checksums for vX.Y.Z"
git push
```

This step is critical — the checksum file must be in the package so Hex.pm users can verify the downloaded NIFs.

## 6. Publish the GitHub release

```bash
gh release edit X.Y.Z --draft=false
```

## 7. Publish to Hex.pm

```bash
mix hex.publish
```

---

## Key Gotchas

- **Tag format**: Use `0.9.1` not `v0.9.1` — the `base_url` in `native.ex` is `releases/download/#{version}`, so the tag and version must match exactly.
- **Checksum before publish**: Always regenerate and commit the checksum file *before* `mix hex.publish`. Without it, users get integrity errors when installing.
- **`--ignore-unavailable`**: Safe to use during checksum generation — skips any targets that failed to build rather than erroring out.
- **Test run option**: The `workflow_dispatch` trigger on the release workflow has a `test_only` input that skips the `gh release upload` step, useful for testing the build matrix without creating a real release.
