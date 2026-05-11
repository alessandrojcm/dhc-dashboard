# Commands

```bash
# Dev (start in order)
pnpm supabase:start        # 1. Start Supabase
pnpm supabase:functions:serve  # 2. Edge functions
pnpm dev                   # 3. SvelteKit dev

# Database
pnpm supabase:types        # Generate types after schema changes
pnpm supabase:reset        # Reset + seed local DB

# Testing
pnpm test:unit             # Vitest
pnpm test:e2e              # Playwright (requires all 3 services)
pnpm check                 # Svelte type check (NOT raw tsc)
```
