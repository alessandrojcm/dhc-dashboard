# Triage labels

The five canonical triage roles and their Linear label/status strings:

| Role | Linear string |
|------|---------------|
| Needs triage | `needs-triage` |
| Needs info | `needs-info` |
| Ready for agent | `ready-for-agent` |
| Ready for human | `ready-for-human` |
| Won't fix | `wontfix` |

## Usage

- `needs-triage`: New issues that haven't been evaluated yet
- `needs-info`: Waiting on reporter for more context
- `ready-for-agent`: Fully specified, can be picked up by an AFK agent with no extra human context
- `ready-for-human`: Requires human implementation or decision
- `wontfix`: Will not be actioned

When using Linear, apply these as labels, statuses, workflow states, or the closest configured equivalent available through `linctl`.
