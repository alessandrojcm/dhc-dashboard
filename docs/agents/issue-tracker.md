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
linctl issue view <issue-id>
```

## Updating triage state

Apply the matching triage label/status string from `docs/agents/triage-labels.md` using `linctl`.

Repository: `alessandrojcm/dhc-dashboard`
