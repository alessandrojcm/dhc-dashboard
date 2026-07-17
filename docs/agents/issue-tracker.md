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

## Wayfinding operations

- Wayfinder maps use `wayfinder:map`; child tickets use exactly one of `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- Create all map tickets first, then attach each child with `linctl issue update <child> --parent <map>`.
- Express blocking with Linear relations: `linctl issue relation add <blocker> --blocks <blocked>`.
- The frontier is the map's open, unassigned children whose blocking relations are all closed. Claim one before work with `linctl issue assign <ticket>`.
- Verify the map and its children with `linctl issue get <map>`, and inspect dependency edges with `linctl issue relation list <ticket>`.
