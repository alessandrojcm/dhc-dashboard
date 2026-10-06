import { describe, expect, it } from "vitest";
import { build } from "vite";
import { cloudflareCreateRequire } from "./cloudflare-create-require.js";

describe("Cloudflare createRequire guard", () => {
	for (const minify of [false, true] as const) {
		it(`guards the actual SSR runtime and preserves sourcemaps (minify: ${minify})`, async () => {
			const result = await build({
				configFile: false,
				logLevel: "silent",
				plugins: [cloudflareCreateRequire()],
				build: {
					ssr: true,
					rolldownOptions: {
						input: [
							"tools/fixtures/create-require.cjs",
							"tools/fixtures/other-require.cjs",
						],
					},
					write: false,
					minify,
					sourcemap: true,
				},
			});
			const outputs = Array.isArray(result) ? result : [result];
			const chunks = outputs.flatMap((output) => {
				if (!("output" in output)) throw new Error("Unexpected watch build");
				return output.output;
			});
			const runtime = chunks.find(
				(chunk) => chunk.type === "chunk" && chunk.name === "rolldown-runtime",
			);
			expect(runtime?.type).toBe("chunk");
			if (runtime?.type !== "chunk")
				throw new Error("Missing Rolldown runtime");
			expect(runtime.code).toMatch(
				/import\.meta\.url\s*\|\|\s*["'`]file:\/\/\/["'`]/,
			);
			// Rolldown's synthetic runtime has no original source/map of its own.
			// Source-backed chunks must still retain mappings after the guard.
			expect(
				chunks.some((chunk) => chunk.type === "chunk" && chunk.map?.mappings),
			).toBe(true);
		});
	}
	it("leaves application code and quoted examples untouched", async () => {
		const result = await build({
			configFile: false,
			logLevel: "silent",
			plugins: [cloudflareCreateRequire()],
			build: {
				ssr: "tools/fixtures/require-example.js",
				write: false,
				minify: false,
			},
		});
		const outputs = Array.isArray(result) ? result : [result];
		const chunks = outputs.flatMap((output) => {
			if (!("output" in output)) throw new Error("Unexpected watch build");
			return output.output;
		});
		const code = chunks
			.map((chunk) => (chunk.type === "chunk" ? chunk.code : ""))
			.join("\n");
		expect(code).toContain('"createRequire(import.meta.url)"');
		expect(code).toContain("createRequire(import.meta.url)");
		expect(code).not.toContain("file:///");
	});
});
