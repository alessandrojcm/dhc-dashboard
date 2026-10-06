import { walk } from "estree-walker";
import MagicString from "magic-string";
import type { Plugin } from "vite";

/**
 * Workaround for sveltejs/kit#15960 (DHC-DASHBOARD-8B).
 * Rolldown's shared CJS helper eagerly calls createRequire(import.meta.url),
 * but workerd supplies no import.meta.url. Remove once the adapter emits a
 * Workers-compatible runtime. Keep Node's normal resolver base when available.
 */
export function cloudflareCreateRequire(): Plugin {
	return {
		name: "cloudflare-create-require",
		apply: "build",
		applyToEnvironment: (environment) => environment.name === "ssr",
		renderChunk(code, chunk) {
			// Only patch the generated helper, never application/dependency code.
			if (chunk.name !== "rolldown-runtime") return null;
			const output = new MagicString(code);
			// SAFETY: this.parse returns an ESTree-compatible module AST; the
			// walker only traverses nodes (it does not inspect Oxc's sourceType).
			walk(this.parse(code) as Parameters<typeof walk>[0], {
				enter(node) {
					if (
						node.type === "CallExpression" &&
						node.callee.type === "Identifier" &&
						node.callee.name === "createRequire" &&
						node.arguments.length === 1
					) {
						const argument = node.arguments[0];
						if (
							argument.type === "MemberExpression" &&
							!argument.computed &&
							argument.object.type === "MetaProperty" &&
							argument.object.meta.name === "import" &&
							argument.object.property.name === "meta" &&
							argument.property.type === "Identifier" &&
							argument.property.name === "url"
						) {
							// SAFETY: Oxc's parser supplies numeric start/end offsets on
							// every node; estree-walker's types omit those extensions.
							const { start, end } = argument as typeof argument & {
								start: number;
								end: number;
							};
							output.overwrite(start, end, 'import.meta.url || "file:///"');
						}
					}
				},
			});
			if (!output.hasChanged()) return null;
			return {
				code: output.toString(),
				map: output.generateMap({ hires: true }),
			};
		},
	};
}
