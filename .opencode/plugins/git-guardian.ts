import { Plugin } from "@opencode-ai/plugin";

/**
 * Git Guardian
 *
 * Blocks the agent from invoking any `git` command in the `shell` tool.
 * Git operations should be performed through GitButler (`but`) instead.
 * Linked Git worktrees are exempt because GitButler cannot manage them.
 */
export default Plugin.define({
  id: "git-guardian",
  async setup(ctx) {
    const gitMetadata = Bun.spawnSync(
      [
        "git",
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
        "--git-common-dir",
      ],
      {
        cwd: ctx.location.directory,
        stdout: "pipe",
        stderr: "ignore",
      },
    );
    const [gitDirectory, gitCommonDirectory] = gitMetadata.stdout
      .toString()
      .trim()
      .split("\n");
    const isLinkedWorktree =
      gitMetadata.exitCode === 0 &&
      Boolean(gitDirectory && gitCommonDirectory) &&
      gitDirectory !== gitCommonDirectory;

    console.info(
      isLinkedWorktree
        ? "Git Guardian disabled in linked Git worktree"
        : "Git Guardian plugin initialized",
    );

    await ctx.tool.hook("execute.before", (event) => {
      if (
        isLinkedWorktree ||
        event.tool !== "shell" ||
        !event.input ||
        typeof event.input !== "object" ||
        !("command" in event.input) ||
        typeof event.input.command !== "string"
      ) {
        return;
      }

      const command = event.input.command.trim();

      // Match `git` as the first word or after common shell separators/prefixes.
      // Catches direct invocations like `git status`, `git add ...`,
      // and shell constructs like `cd foo && git log`.
      const gitPattern = /(^|&&|;|\|\||`|\$\()\s*git\b/;

      if (gitPattern.test(command)) {
        console.warn("Git Guardian blocked git command", {
          command: command.slice(0, 200),
        });

        throw new Error(
          "Direct `git` commands are not allowed. Use GitButler (`but`) instead.\n" +
            "Run `but --help` or `but diff` to get started.\n" +
            "See the `but` skill for common workflows.",
        );
      }
    });
  },
});
