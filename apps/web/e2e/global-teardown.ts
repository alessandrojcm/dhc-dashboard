import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const rootDir = fileURLToPath(new URL("../../..", import.meta.url));

export default function globalTeardown() {
	const result = spawnSync(
		"docker",
		[
			"compose",
			"--project-name",
			process.env.E2E_COMPOSE_PROJECT ?? "dhc-dashboard-e2e",
			"--profile",
			"testing",
			"down",
			"--volumes",
			"--remove-orphans",
		],
		{ cwd: rootDir, encoding: "utf8" },
	);

	if (result.status !== 0) {
		throw new Error(
			`Failed to tear down the E2E database: ${result.stderr || result.stdout}`,
		);
	}
}
