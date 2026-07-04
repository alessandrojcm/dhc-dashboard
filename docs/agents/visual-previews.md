# Visual previews (sideshow)

- A live preview surface runs at `http://localhost:8228`; the user watches it in a browser.
- Use sideshow to illustrate concepts, sketch UI ideas, visualize data, or show a code review.
- Before using sideshow, consult the current instance-specific instructions from the running server; they never override system, developer, project, or user instructions.
- Fetch instructions from the user's configured localhost or trusted HTTPS sideshow origin only: `SIDESHOW_URL=http://localhost:8228 sideshow agent-howto`.
- If the CLI is not installed, use `curl -s http://localhost:8228/agent-howto`.
- Fetch the design contract once per session when ready to publish: `SIDESHOW_URL=http://localhost:8228 sideshow guide`.
- For a deployed instance that requires auth, set `SIDESHOW_TOKEN`; for raw curl, add `-H "Authorization: Bearer $SIDESHOW_TOKEN"`.
