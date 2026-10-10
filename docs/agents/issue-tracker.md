# Issue tracker

Issues are tracked in **Linear** through the `linear` MCP server (configured in `opencode.json`; authenticate with `/mcps`).

## Workflow

Use the Linear MCP tools for issue operations in this repo. Do not use GitHub Issues or local `.scratch/` markdown issues unless the repo configuration changes.

Issue identifiers follow the format `ALE-123`.

Create issues with the appropriate team/project, title, description, and triage label/status.

## Tool usage

Tools come from the `linear` MCP server. Under Code Mode they are grouped as `tools.linear.*`; exact tool names evolve, so check the current catalog (e.g. `search({ query: "linear" })` in Code Mode) instead of guessing:

- Search/list, read, create, and update issues (the server has a unified save tool for create+update).
- Comments, labels, and workflow states.
- Projects, project milestones, and initiatives.

A read-only endpoint (`https://mcp.linear.app/mcp/readonly`) exists, but this repo configures the read-write endpoint.

## Updating triage state

Apply the matching triage label/status string from `docs/agents/triage-labels.md` with the issue tools.

Repository: `alessandrojcm/dhc-dashboard`

## Workspace limits and housekeeping

- The team is `Alessandrojcm` (issue keys `ALE-123`). Its type labels are `Bug`, `Improvement`, and `Feature`, plus the team-level `wayfinder:*` labels (`list_issue_labels` without a team filter shows only the workspace labels, so don't recreate them); the triage strings in `triage-labels.md` do not exist as labels, so map them to the workflow state (`Todo` = ready) and state the triage role in the description.
- The workspace is on Linear's free plan. Creating an issue fails with `You've exceeded the free issue limit for this workspace` once the active-issue cap is reached; archiving issues frees capacity.
- To archive in bulk, use `linctl graphql` (linctl has no archive subcommand): list `issues(filter:{state:{name:{eq:"Done"}}})`, then run `mutation($id:String!){ issueArchive(id:$id){ success } }` per id. When calling `linctl graphql --query` in a shell loop, redirect stdin from `/dev/null`; otherwise linctl treats the loop's stdin as a second query source and rejects every call.

## Projects & milestones

- Feature tickets may target the `DHC Dashboard` project for release grouping.
- Project milestones are supported by the Linear MCP tools (create/edit project milestones, add/remove issues to milestones); there is no need for raw GraphQL.

## Wayfinding operations

- Wayfinder maps use `wayfinder:map`; child tickets use exactly one of `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
- Create all map tickets first, then attach each child under the map issue as its parent.
- Express blocking with Linear issue relations.
- The frontier is the map's open, unassigned children whose blocking relations are all closed. Claim one before work by assigning the ticket.
- Verify the map and its children by reading them, and inspect dependency edges through the issue's relations.

## Free-plan issue limit

The workspace is on Linear's free plan, which counts non-archived issues. When `save_issue` fails with "exceeded the free issue limit", archive old Done issues. The Linear MCP server has no archive tool, so use the authenticated `linctl` CLI:

```bash
linctl graphql -q 'query { issues(first: 15, filter: { state: { type: { eq: "completed" } } }, sort: [{ completedAt: { order: Ascending } }]) { nodes { identifier title } } }'
linctl graphql -q 'mutation { issueArchive(id: "ALE-123") { success } }'
```

Skip parent issues whose children are still open. `linctl graphql` also covers anything else the MCP tools lack.

## Relation direction gotcha

Agents keep entering blocking relations backwards. A relation points **from the blocker toward the blocked issue**: a blocking relation **from ALE-A to ALE-B** means **ALE-A must finish before ALE-B** (ALE-A is the prerequisite, ALE-B is the dependent). Equivalently, read it as "ALE-A blocks ALE-B."

When sequencing an expand→code→contract split (e.g. ALE-179), the correct edges are: expand blocks code, and code blocks contract. The expand migration is the frontier, not the contract. Before treating a Linear-reported "unblocked" issue as the frontier, cross-check it against the spec's stated ordering — if Linear's graph disagrees with the spec, the relations are inverted and must be fixed (remove the wrong edge, then add the correct one) before claiming the ticket.