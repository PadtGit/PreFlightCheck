---
name: pfc-release
description: Use when Bob asks to cut, prepare, or publish a PreFlightCheck release (bump VERSION, update CHANGELOG, tag vX.Y.Z, attach the ready-to-run ZIP).
disable-model-invocation: true
---

# PreFlightCheck release

Prepare a release on a branch, merge through a PR, then publish. Ask Bob which segment to bump
(patch/minor) when the request does not say. Never push tags or publish a release without his go-ahead.

## Prepare (on a `release/<version>` or fix branch)

1. Set `VERSION` to `X.Y.Z` (digits only; `tools/New-ReleaseArchive.ps1` rejects anything else).
2. Update the `Version:` line near the top of `README.md`.
3. Move the `Unreleased` entries into a new `## X.Y.Z - YYYY-MM-DD` section at the top of
   `CHANGELOG.md`, with user-facing bullets in the existing past-tense, behavior-first style.
   Summarize from `git log vPREV..HEAD`, then leave an empty `## Unreleased` section above it.
4. Verify locally in PowerShell 7 (same versions as CI: Pester 6.2.0, PSScriptAnalyzer 1.25.0; see the
   `pfc-verify` skill), then build the archive:

   ```powershell
   pwsh -NoProfile -File ./tools/Invoke-LocalVerify.ps1
   ./tools/New-ReleaseArchive.ps1 -OutputDirectory "$env:TEMP\pfc-release-check"
   ```

   Inspect the ZIP's file list, then delete the temporary output.
5. Commit, push, open a PR to `main`, and wait for `powershell-verification` to pass.

## Publish (after the PR is merged)

```powershell
git switch main; git pull --ff-only
gh release create "v$((Get-Content VERSION -Raw).Trim())" --target main --title "PreFlightCheck vX.Y.Z" --notes-file <changelog-section>
```

The tag must be `v` + `VERSION` or `.github/workflows/release-archive.yml` fails. Confirm the workflow attached
`PreFlightCheck-X.Y.Z.zip` with `gh release view vX.Y.Z`.
