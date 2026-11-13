import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

test("production fnox reads every configured secret from Doppler", () => {
	const config = read("fnox.toml");

	assert.match(config, /^default_provider = "doppler"$/m);
	assert.match(config, /^\[providers\.doppler\]$/m);
	assert.match(config, /^type = "doppler"$/m);
	assert.match(config, /^project = "dhc-dashboard"$/m);
	assert.match(config, /^config = "prd"$/m);
	assert.doesNotMatch(config, /1password|1Password/);

	for (const line of config.split("\n")) {
		if (line.includes("provider =")) {
			assert.match(line, /provider = "doppler"/);
		}
	}
});

test("the production image installs Doppler for fnox", () => {
	const dockerfile = read("apps/phoenix/Dockerfile");

	assert.match(dockerfile, /packages\.doppler\.com\/public\/cli\/gpg\.DE2A7741A397C129\.key/);
	assert.match(dockerfile, /packages\.doppler\.com\/public\/cli\/deb\/debian any-version main/);
	assert.match(dockerfile, /apt-get install -y --no-install-recommends doppler/);
	assert.doesNotMatch(dockerfile, /1password/i);
});

test("Fly and local Doppler bootstrap tokens stay distinct in deployment docs", () => {
	const readme = read("apps/phoenix/README.md");
	const commands = read("docs/agents/commands.md");
	const envExample = read(".env.example");

	for (const document of [readme, commands, envExample]) {
		assert.match(document, /FNOX_DOPPLER_TOKEN/);
	}

	assert.match(commands, /local development instead uses a logged-in Doppler CLI or `DOPPLER_TOKEN`/);
	assert.match(envExample, /authenticate the Doppler CLI with `doppler login` or set\n# DOPPLER_TOKEN/);
});

test("the deployment guide distinguishes runtime-optional features from fnox defaults", () => {
	const readme = read("apps/phoenix/README.md");

	assert.match(
		readme,
		/the five `TRAINING_CALENDAR_\*` mappings have inactive defaults/i,
	);
	assert.match(readme, /"Optional" for those features describes runtime behavior, not production-secret provisioning/);
});
