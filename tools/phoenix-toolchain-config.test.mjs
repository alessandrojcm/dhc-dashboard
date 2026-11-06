import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(
	new URL("./phoenix-toolchain-config.sh", import.meta.url),
);
const source = `[tools]
erlang = "29"
elixir = "1.20.5"
fnox = "latest"
node = "26"

[env]
_.file = ".env"

[tasks.build]
run = "echo build"
`;

/**
 * @param {import("node:test").TestContext} t
 * @param {string} config
 */
function generate(t, config) {
	const directory = mkdtempSync(join(tmpdir(), "phoenix-toolchain-config-"));
	t.after(() => rmSync(directory, { recursive: true, force: true }));
	const input = join(directory, "source.toml");
	const output = join(directory, "output");
	writeFileSync(input, config);
	const result = spawnSync("bash", [script, input, output], {
		encoding: "utf8",
	});
	return {
		result,
		read() {
			assert.equal(result.status, 0, result.stderr);
			return {
				beam: readFileSync(join(output, "beam.toml"), "utf8"),
				runtime: readFileSync(join(output, "runtime.toml"), "utf8"),
			};
		},
	};
}

test("projects only the tools each production stage installs", (t) => {
	assert.deepEqual(generate(t, source).read(), {
		beam: '[tools]\nerlang = "29"\nelixir = "1.20.5"\n',
		runtime: '[tools]\nfnox = "latest"\n',
	});
});

test("unrelated tools, tasks, environment and comments keep identical cache inputs", (t) => {
	const changed = source
		.replace('node = "26"', 'node = "27"\nentire = "latest"')
		.replace('_.file = ".env"', 'EXAMPLE = "changed"')
		.replace("echo build", "echo changed");
	assert.deepEqual(
		generate(t, `${changed}\n# a new comment\n`).read(),
		generate(t, source).read(),
	);
});

for (const [tool, version] of [
	["erlang", "30"],
	["elixir", "1.21.0"],
	["fnox", "1.0.0"],
]) {
	test(`${tool} changes invalidate only the relevant toolchain`, (t) => {
		const before = generate(t, source).read();
		const after = generate(
			t,
			source.replace(
				new RegExp(`^${tool} = .*`, "m"),
				`${tool} = "${version}"`,
			),
		).read();
		const changed = tool === "fnox" ? "runtime" : "beam";
		const unchanged = tool === "fnox" ? "beam" : "runtime";
		assert.notEqual(after[changed], before[changed]);
		assert.equal(after[unchanged], before[unchanged]);
	});
}

test("reads TOML rather than depending on line layout or comments", (t) => {
	const equivalent = source
		.replace('erlang = "29"', "\"erlang\" = '29' # OTP")
		.replace('elixir = "1.20.5"', "elixir='1.20.5'");
	assert.deepEqual(generate(t, equivalent).read(), generate(t, source).read());
});

test("projects the repository's real mise config", (t) => {
	const repositoryConfig = readFileSync(
		new URL("../.mise.toml", import.meta.url),
		"utf8",
	);
	const { beam, runtime } = generate(t, repositoryConfig).read();
	assert.match(beam, /^\[tools\]\nerlang = "[^"\n]+"\nelixir = "[^"\n]+"\n$/);
	assert.match(runtime, /^\[tools\]\nfnox = "[^"\n]+"\n$/);
});

for (const [name, invalid] of [
	["a missing tool", source.replace('erlang = "29"', "")],
	["an empty version", source.replace('erlang = "29"', 'erlang = ""')],
	[
		"a tool options table",
		source.replace('erlang = "29"', 'erlang = { version = "29" }'),
	],
	["malformed TOML", "not valid TOML"],
]) {
	test(`refuses ${name}`, (t) => {
		const { result } = generate(t, invalid);
		assert.notEqual(result.status, 0);
		assert.ok(result.stderr.trim(), "failure must explain the invalid input");
	});
}
