# Triage labels

The five canonical triage roles and their label strings:

| Role | Label |
|------|-------|
| Needs triage | `needs-triage` |
| Needs info | `needs-info` |
| Ready for agent | `ready-for-agent` |
| Ready for human | `ready-for-human` |
| Won't fix | `wontfix` |

The repo already has `wontfix` configured. The other four may need to be created in GitHub if they don't exist yet.

## Usage

- `needs-triage`: New issues that haven't been evaluated yet
- `needs-info`: Waiting on reporter for more context
- `ready-for-agent`: Fully specified, can be picked up by an AFK agent
- `ready-for-human`: Requires human implementation or decision
- `wontfix`: Will not be actioned
