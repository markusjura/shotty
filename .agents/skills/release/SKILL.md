---
name: release
description: Use when asked to release or publish the app, or when `release` is written as a workflow command.
---

## Arguments

- Optional bump: `patch` (default), `minor`, `major`, or an exact `X.Y.Z` above the current version.

## Process

1. Run `Scripts/release.sh [bump]` from a clean tree whose HEAD contains `origin/main`. It bumps `Config/Version.xcconfig`, pushes `chore: release <version>` and tag `v<version>` to `main`, packages the ZIP and DMG, installs and launches the app from `/Applications`, then publishes the GitHub release with the DMG, plus the signed ZIP and `appcast.xml` that installed copies update from.
2. If a step after the push fails, fix the cause and run only the remaining steps the script prints. To retry only publishing, run `Scripts/publish.sh <version>`. Never rerun `release.sh` for the same release; it would bump again.

Completes when the GitHub release URL is confirmed and the installed app reports the new version.

## Response

Return the version, release URL, and any blocker.
