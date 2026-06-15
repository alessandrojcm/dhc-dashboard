# Domain docs

## Layout

Single-context monorepo. One global `CONTEXT.md` at the repo root plus `docs/adr/` for architecture decision records.

## Files

- `CONTEXT.md` — Domain glossary & architecture overview
- `docs/adr/` — Architecture Decision Records
- `docs/agents/` — Agent-specific documentation (patterns, commands, tech stack)

## Consumer rules

When working on this codebase:
1. Read `CONTEXT.md` first to understand domain language
2. Check `docs/adr/` for decisions that constrain the area you're touching
3. Follow `docs/agents/critical-patterns.md` and `docs/agents/anti-patterns.md`
