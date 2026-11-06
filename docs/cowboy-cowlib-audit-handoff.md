# Handoff: unblock Phoenix dependency audit after ALE-437

Prepared 6 November 2026. This is a dependency-remediation handoff, not a new
application security audit. Fix the two unignored advisories below and get
`mix precommit` green without suppressing their findings.

## Starting evidence

After the two-axis review fixes, ALE-437 verification ran the full Phoenix suite:
**3,082 passed, 4 default opt-in integration exclusions**. Compilation with warnings as errors,
format checking, Credo `--all` and Reach architecture checks passed.
`mix precommit` still exited 1 because `hex.audit` reported:

| Locked package | Advisory | Reported problem |
| --- | --- | --- |
| `cowlib 2.21.0` | [CVE-2026-113431](https://osv.dev/vulnerability/EEF-CVE-2026-113431) | Unbounded decoded HTTP/2 header lists can amplify memory use in a server consumer. |
| `cowboy 2.18.0` | [CVE-2026-115701](https://osv.dev/vulnerability/EEF-CVE-2026-115701) | HTTP/1.1 pipelined data can be buffered without a bound while a handler runs. |

These are dependency advisory matches, not proof that the deployed dashboard is
exploitable. The Phoenix endpoint is configured with `Bandit.PhoenixAdapter`.
Do not claim a production exposure or exemption without checking the actual
dependency paths and runtime usage.

## Release availability: do not guess a fixed version

Checked the OSV records and Hex package APIs on 6 November 2026:

- Latest Hex Cowlib: **2.21.0**, still affected.
- Latest Hex Cowboy: **2.20.0**, still in the advisory's affected range.
- Neither advisory lists a fixed Hex release. Both identify upstream Git fixes:
  - Cowlib: [`a3b15e29b3067644bfd580246c87f7af7a90b3b8`](https://github.com/ninenines/cowlib/commit/a3b15e29b3067644bfd580246c87f7af7a90b3b8).
  - Cowboy: [`3a630c07e1521abf63a1b9ea080509aa1337b60d`](https://github.com/ninenines/cowboy/commit/3a630c07e1521abf63a1b9ea080509aa1337b60d).

Recheck release availability when starting. Upgrading Cowboy to 2.20.0 alone
does not establish a fix. If patched Hex releases are unavailable, investigate
minimal immutable upstream Git pins containing the fixes, with compatibility
verification and a documented return-to-Hex condition. A Git dependency no
longer appearing in `hex.audit` is **not** evidence of remediation: verify the
patched source itself. If that route cannot be verified, report the blocker
rather than add an ignore entry to manufacture a green check.

Primary package metadata:
[Cowlib](https://hex.pm/api/packages/cowlib),
[Cowboy](https://hex.pm/api/packages/cowboy).

## Relevant repository seams

- `apps/phoenix/mix.exs`: dependency constraints, documented advisory exceptions,
  and the `precommit` alias. Keep `hex.audit` first in that alias.
- `apps/phoenix/mix.lock`: exact resolutions and transitive constraints.
- `apps/phoenix/config/config.exs`: Bandit endpoint adapter.
- `apps/phoenix/AGENTS.md`: dependency/runtime constraints and test conventions.
- `docs/agents/commands.md`: Phoenix checks and Colima test-harness setup.

Current lockfile paths include:

```text
Bypass 2.1.0 (only: :test)
  -> plug_cowboy 2.9.0 -> cowboy 2.18.0 -> cowlib 2.21.0

Nostrum 0.10.4
  -> Gun 2.7.0 -> cowlib 2.21.0
```

Cowlib therefore must not be dismissed as test-only merely because Cowboy is
pulled by Bypass. Gun currently requires Cowlib `>= 2.21.0 and < 3.0.0`;
downgrading Cowlib would also undo previous security fixes. Confirm the complete
environment-specific graph using the installed Mix task help before changing it.

Keep the existing reviewed Hackney and response-splitting advisory exceptions
separate. Do not broaden them to cover these two new findings. Keep Hackney
test-only and retain the existing Gun/Mint/Finch compatibility constraints unless
the selected remediation genuinely requires a narrowly justified change.

## Work to perform

1. Read repository instructions and inspect current changes with GitButler.
   The checkout contains Calendar work and may contain unrelated frontend or
   tooling changes. Preserve all of them; do not reset, broadly stage, or rewrite
   another task's work.
2. Reproduce the current audit with `MIX_ENV=test mix hex.audit`. Read
   `mix help hex.audit`, `mix help deps.tree` and `mix help deps.update` before
   selecting dependency commands. Use `mise exec --` for the pinned toolchain.
3. Verify current upstream fixes/releases and choose the smallest compatible
   dependency change. Update constraints and the lockfile together. Avoid a
   blanket dependency refresh or a transport-library migration.
4. Verify development, test and production dependency resolution. Preserve
   Discord REST behavior, Req-only application HTTP, Bypass tests and the
   Testcontainers Docker Unix-socket transport. Record any new pin/floor and its
   reason in the existing dependency guidance.
5. Run the verification below and resolve regressions caused by the dependency
   change. Do not probe availability vulnerabilities against live services.

## Verification and completion

Generate email shells before direct Mix compilation if the artifacts are absent:
`mise run email-shells` from the repository root. From `apps/phoenix`, use the
existing test harness; on this machine Colima needs both socket settings:

```sh
mise exec -- mix credo --all
mise exec -- mix format --check-formatted
mise exec -- env MIX_ENV=prod mix compile --warnings-as-errors
mise exec -- env DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock mix precommit
```

Completion requires a real source/dependency fix for both advisories, a green
audit and full precommit, and a reviewed diff containing only the remediation.
Do not skip tests, expand advisory ignores, remove the audit, or treat scanner
blindness as a fix. Report verified versions/refs, compatibility evidence and
check results. No production deployment or Calendar activation is authorized by
this handoff.

## What follows

ALE-437 is the final implementation child currently listed under ALE-429; there
is no later Calendar implementation child in that sequence. Its scoped behavior
is documented in `docs/workshop-calendar.md`: preview and explicit activation,
automatic sync/retries, Sentry failures, no Calendar UI or operator recovery tools.

After remediation, review and land the Calendar changes, then deploy migrations
and code with sending inactive. Separately authorized administrator setup supplies
the organizer, two owned calendars, OAuth credentials and committee read-only
sharing. Next run the read-only launch preview, resolve required schedule data,
and obtain explicit authorization before production activation. Do not restore
the removed pause/resume, address-repair or broad acceptance-programme scope.

Some earlier Calendar tickets still show Todo in Linear despite their code being
present locally. Reconcile their status against reviewed/landed changes; do not
reimplement them merely because of that tracker state.
