import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
	new URL("../.github/workflows/deploy-phoenix-fly.yml", import.meta.url),
	"utf8",
);
const deploy = workflow.split(/^  deploy:\s*$/m)[1];
const dockerfile = readFileSync(
	new URL("../apps/phoenix/Dockerfile", import.meta.url),
	"utf8",
);

test("the latest Phoenix run deploys even if its own commit has no backend changes", () => {
	// GitHub replaces pending runs even with cancel-in-progress: false. A
	// per-push diff on the surviving run can omit a cancelled run's API changes.
	assert.ok(deploy, "Phoenix must have a deploy job");
	assert.doesNotMatch(deploy, /^    (?:if|needs):/m);
	assert.doesNotMatch(workflow, /dorny\/paths-filter/);
});

test("every main push and manual recovery can reach the deploy job", () => {
	assert.match(workflow, /^  push:\n    branches:\n      - main$/m);
	assert.match(workflow, /^  workflow_dispatch:/m);
	assert.doesNotMatch(workflow, /^    paths(?:-ignore)?:/m);
});

test("a newer push cannot interrupt an in-progress Phoenix rollout", () => {
	assert.match(workflow, /^  group: deploy-phoenix-fly$/m);
	assert.match(workflow, /^  cancel-in-progress: false$/m);
});

test("production tool installs depend on projected versions, not the whole mise config", () => {
	const builder = dockerfile.split(/^FROM .* AS builder$/m)[1];
	const runner = dockerfile.split(/^FROM .* AS runner$/m)[1];
	assert.ok(builder);
	assert.ok(runner);
	assert.doesNotMatch(builder, /^COPY \.mise\.toml /m);
	assert.doesNotMatch(runner, /^COPY \.mise\.toml /m);
	assert.match(
		builder,
		/^COPY --from=toolchain-config \/toolchains\/beam\.toml \.mise\.toml$/m,
	);
	assert.match(
		runner,
		/^COPY --from=toolchain-config \/toolchains\/runtime\.toml \.mise\.toml$/m,
	);
});

test("changing secret references does not reinstall fnox", () => {
	const runner = dockerfile.split(/^FROM .* AS runner$/m)[1];
	assert.ok(runner);
	assert.match(
		runner,
		/^RUN mise trust -a && mise install fnox.*\nCOPY --chown=nobody:root fnox\.toml \.\/$/m,
	);
});
