# Issue tracker

Issues are tracked in **Linear** using the `linctl` CLI.

## Workflow

Use `linctl` for issue operations in this repo. Do not use GitHub Issues or local `.scratch/` markdown issues unless the repo configuration changes.

Issue identifiers follow the format `DHC-123`.

Use the Linear CLI to create an issue with the appropriate team/project, title, description, and triage label/status.

```bash
linctl issue create --title "Title" --description "Body"
```

## CLI usage

```bash
linctl issue list
```

## Viewing an issue

```bash
linctl issue get <issue-id>
```

This installed `linctl` does not provide `issue view`; use `issue get` for issue details.

## Updating triage state

Apply the matching triage label/status string from `docs/agents/triage-labels.md` using `linctl`.

Repository: `alessandrojcm/dhc-dashboard`

## Projects & milestones

- Feature tickets may target the `DHC Dashboard` project: `linctl issue create --team ALE --project "DHC Dashboard" ...`, optionally with `--project-milestone <name>` for release grouping (e.g. `v3`).
- linctl has no milestone management subcommand. Create milestones via raw GraphQL:
  `linctl graphql -q 'mutation { projectMilestoneCreate(input: { projectId: "<project-uuid>", name: "<name>" }) { success projectMilestone { id name } } }'`
  Get the project UUID from `linctl project list -j` / `linctl project get`.

## Wayfinding operations

- Wayfinder maps use `wayfinder:map`; child tickets use exactly one of `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- Create all map tickets first, then attach each child with `linctl issue update <child> --parent <map>`.
- Express blocking with Linear relations: `linctl issue relation add <blocker> --blocks <blocked>`.
- The frontier is the map's open, unassigned children whose blocking relations are all closed. Claim one before work with `linctl issue assign <ticket>`.
- Verify the map and its children with `linctl issue get <map>`, and inspect dependency edges with `linctl issue relation list <ticket>`.

## Relation direction gotcha

Agents keep entering `--blocks` relations backwards. The flag points **from the blocker toward the blocked issue**: `linctl issue relation add ALE-A --blocks ALE-B` means **ALE-A must finish before ALE-B** (ALE-A is the prerequisite, ALE-B is the dependent). Equivalently, read it as "ALE-A blocks ALE-B."

When sequencing an expand→code→contract split (e.g. ALE-179), the correct edges are: expand `--blocks` code, and code `--blocks` contract. The expand migration is the frontier, not the contract. Before treating a Linear-reported "unblocked" issue as the frontier, cross-check it against the spec's stated ordering — if Linear's graph disagrees with the spec, the relations are inverted and must be fixed (`relation remove` the wrong edge, then `relation add` the correct one) before claiming the ticket.
