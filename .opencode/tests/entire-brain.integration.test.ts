import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

test("Entire Brain loads through OpenCode's actual V2 plugin runtime", () => {
  const directory = fileURLToPath(new URL("../../", import.meta.url));
  const output = execFileSync(
    "opencode",
    ["api", "plugin.list", "--header", `x-opencode-directory:${encodeURIComponent(directory)}`],
    { cwd: directory, encoding: "utf8", timeout: 15_000 },
  );
  const result = JSON.parse(output) as {
    data: Array<{
      id?: string;
      source: { path?: string };
      state: { status: string; error?: string };
    }>;
  };
  const brain = result.data.find((plugin) =>
    plugin.source.path?.endsWith("/.opencode/plugins/entire-brain.ts"),
  );
  expect(brain).toBeDefined();
  expect(brain?.id).toBe("entire-brain");
  expect(brain?.state).toEqual({ status: "active" });
}, 20_000);
