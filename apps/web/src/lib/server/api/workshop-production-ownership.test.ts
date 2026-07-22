import { readdir, readFile } from "node:fs/promises";
import { extname, relative, resolve } from "node:path";
import { describe, expect, test } from "vitest";

const sourceRoot = resolve(process.cwd(), "src");
const legacyWorkshopServices = resolve(
	sourceRoot,
	"lib/server/services/workshops",
);

async function productionSourceFiles(directory: string): Promise<string[]> {
	const entries = await readdir(directory, { withFileTypes: true });
	const files = await Promise.all(
		entries.map(async (entry) => {
			const path = resolve(directory, entry.name);

			if (entry.isDirectory()) {
				if (path === legacyWorkshopServices) return [];
				return productionSourceFiles(path);
			}

			if (entry.name.includes(".test.") || entry.name.includes(".spec.")) {
				return [];
			}

			return [".ts", ".svelte"].includes(extname(entry.name)) ? [path] : [];
		}),
	);

	return files.flat();
}

describe("Workshop production ownership", () => {
	test("production source does not import the legacy Svelte Workshop services", async () => {
		const violations: string[] = [];

		for (const file of await productionSourceFiles(sourceRoot)) {
			const source = await readFile(file, "utf8");
			if (source.includes("server/services/workshops")) {
				violations.push(relative(sourceRoot, file));
			}
		}

		expect(violations).toEqual([]);
	});
});
