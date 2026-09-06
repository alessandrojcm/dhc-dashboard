import { Plugin } from "@opencode-ai/plugin";

/**
 * Git Guardian
 *
 * Blocks the agent from invoking any `git` command through the `shell` tool.
 * Git operations should be performed through GitButler (`but`) instead.
 * Linked Git worktrees are exempt because GitButler cannot manage them.
 *
 * V2 implementation: denial happens in a `permission.evaluate` hook, which is
 * the documented V2 interception point (a hook may change `effect` to `allow`,
 * `ask`, or `deny`). The hook runs for `allow`/`ask` decisions, so the guardian
 * stays authoritative even when an agent policy would allow the command.
 */
export default Plugin.define({
  id: "git-guardian",
  async setup(ctx) {
    const isLinkedWorktree = await detectLinkedWorktree(
      ctx.location.directory,
    );

    console.info(
      isLinkedWorktree
        ? "Git Guardian disabled in linked Git worktree"
        : "Git Guardian plugin initialized",
    );

    await ctx.permission.hook("evaluate", (event) => {
      if (isLinkedWorktree || event.action !== "shell") {
        return;
      }

      const blocked = event.resources.some(
        (resource) =>
          typeof resource === "string" && GIT_PATTERN.test(resource.trim()),
      );

      if (blocked) {
        event.effect = "deny";
        event.message =
          "Direct `git` commands are not allowed. Use GitButler (`but`) instead.\n" +
          "Run `but --help` or `but diff` to get started.\n" +
          "See the `but` skill for common workflows.";
      }
    });
  },
});

// Match `git` as the first word or after common shell separators/prefixes.
// Catches direct invocations like `git status`, `git add ...`,
// and shell constructs like `cd foo && git log`.
const GIT_PATTERN = /(^|&&|;|\|\||`|\$\()\s*git\b/;

async function detectLinkedWorktree(directory: string): Promise<boolean> {
  try {
    const runtime = (globalThis as { Bun?: unknown }).Bun as
      | {
          spawnSync: (
            cmd: string[],
            opts: Record<string, unknown>,
          ) => { exitCode: number; stdout: Uint8Array };
        }
      | undefined;
    if (!runtime) {
      return false;
    }
    const gitMetadata = runtime.spawnSync(
      [
        "git",
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
        "--git-common-dir",
      ],
      {
        cwd: directory,
        stdout: "pipe",
        stderr: "ignore",
      },
    );
    const [gitDirectory, gitCommonDirectory] = new TextDecoder()
      .decode(gitMetadata.stdout)
      .trim()
      .split("\n");
    return (
      gitMetadata.exitCode === 0 &&
      Boolean(gitDirectory && gitCommonDirectory) &&
      gitDirectory !== gitCommonDirectory
    );
  } catch {
    // Fail closed: when detection is unavailable the guardian stays active.
    return false;
  }
}
