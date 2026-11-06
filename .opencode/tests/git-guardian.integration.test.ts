import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// Exercise OpenCode's actual loader: a plain Bun import uses a different Effect runtime.
// Requires the installed OpenCode CLI and its shared server.
test("Git Guardian loads in the project's OpenCode server", () => {
  const directory = fileURLToPath(new URL("../../", import.meta.url));
  const output = execFileSync(
    "opencode",
    [
      "api",
      "plugin.list",
      "--header",
      `x-opencode-directory:${encodeURIComponent(directory)}`,
    ],
    { cwd: directory, encoding: "utf8", timeout: 15_000 },
  );
  const result = JSON.parse(output) as {
    data: Array<{
      id?: string;
      source: { path?: string };
      state: { status: string; error?: string; ref?: string };
    }>;
  };
  const guardian = result.data.find((plugin) =>
    plugin.source.path?.endsWith("/.opencode/plugins/git-guardian.ts"),
  );

  expect(guardian).toBeDefined();
  expect(guardian?.state).toEqual({ status: "active" });
  expect(guardian?.id).toBe("git-guardian");
}, 20_000);
