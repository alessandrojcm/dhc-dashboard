import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
	new URL("../.github/workflows/deploy-phoenix-fly.yml", import.meta.url),
	"utf8",
);
const deploy = workflow.split(/^  deploy:\s*$/m)[1];

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
