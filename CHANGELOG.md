# Remove-OldFiles - Change History

## Unreleased — 2.0.0-alpha1

- Add standalone HTML reporting with embedded CSS, explicit scan outcomes and escaped data.
- Protect report destinations from accidental overwrite and writes inside scan scope; support Force and WhatIf.
- Include a labelled synthetic sample and exporter acceptance tests.

- Add a separate report-only retention module for one strictly validated policy.
- Report candidates, exclusions and failures with fixed UTC retention cutoffs.
- Protect ignore-marked subtrees and skip links/reparse points.
- Add Pester acceptance tests, usage notes and a cross-platform test workflow.
- Keep the legacy script and CSV unchanged; CSV migration and deletion are not implemented yet.

## Version 1.1.0

- Updated *Logging* function to latest verison
- Fixed typo in logging message
- Updated file encoding

## Version 1.0.0

- Initial release
