# Progress — night build 2026-10-12

## Toolchain (checked 2026-10-12 ~22:45 IST, macOS 26.6.2 x86_64)
| Tool | Version | Note |
| --- | --- | --- |
| git | 2.50.1 | |
| node | v24.11.0 | CI uses Node 22 |
| pnpm | 11.23.0 | |
| dart | 3.12.2 | |
| flutter | 3.44.2 stable | |
| docker | Docker Desktop 4.88.0 installed; daemon did not come up during the session (`docker info` hung) | see MORNING.md Blocked |
| postgres | local Postgres 18 binaries used to run a private throwaway cluster on :5433 in `.localdb/` (gitignored) for tests | compose uses postgres:16 |
| gitleaks | installed via Homebrew during session | |

## Milestones
