// SvelteKit 3's dev `$app/env/public` module inlines `static` variables and
// reads the rest from `globalThis.__sveltekit_dev.env`, which the HTML that
// SvelteKit renders defines before any app code runs. Vitest's browser runner
// serves its own page, so stand in for that bootstrap: dynamic public
// variables are unset here, exactly as when they are absent from the
// environment (`src/env.ts` declares them optional). SvelteKit 3.0 notes it
// does not yet provide this global under Vitest (`exports/vite/index.js`).
Object.defineProperty(globalThis, "__sveltekit_dev", {
	value: { env: {} },
	configurable: true,
});
