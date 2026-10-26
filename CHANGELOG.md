# Remove-OldFiles - Change History

## Unreleased — 2.0.0-alpha1

- Add an isolated PostgreSQL prototype for immutable policy revisions, exclusive report-run claims and run history.
- Hold expired runs for explicit reconciliation; reject central deletion results and conflicting completion retries.
- Add disposable database contract/concurrency checks and a dedicated CI job; leave module execution unchanged.

- Separate the five public commands and eight private helpers into one-function files with an explicit loader.
- Add a portable module-directory builder, manifest file list and package-boundary tests.
- Preserve the existing cleanup command parameters and safety behaviour during the structural refactor.

- Add opt-in single-policy cleanup with a report-only default and ShouldProcess preview/confirmation.
- Block execution after incomplete scans; recheck scope, links, ignore markers and metadata before and after confirmation.
- Record individual outcomes and count removals only after success; reject execution snapshots in the report-only HTML exporter.
- Apply brace-only-line/four-space style to rebuilt code, with editor settings and a CI style check.

- Import legacy CSV policies with visible defaults, strict conversion and source-row diagnostics.
- Detect duplicate/nested scopes and block incomplete or ambiguous batches before scanning.
- Add report-only multi-policy runs with a shared evaluation time and 25 migration/batch tests.

- Add standalone HTML reporting with embedded CSS, explicit scan outcomes and escaped data.
- Protect report destinations from accidental overwrite and writes inside scan scope; support Force and WhatIf.
- Include a labelled synthetic sample and exporter acceptance tests.

- Add a separate report-only retention module for one strictly validated policy.
- Report candidates, exclusions and failures with fixed UTC retention cutoffs.
- Protect ignore-marked subtrees and skip links/reparse points.
- Add Pester acceptance tests, usage notes and a cross-platform test workflow.
- Keep the legacy script and CSV unchanged; rebuilt functionality lives in the separate module.

## Version 1.1.0

- Updated *Logging* function to latest verison
- Fixed typo in logging message
- Updated file encoding

## Version 1.0.0

- Initial release
