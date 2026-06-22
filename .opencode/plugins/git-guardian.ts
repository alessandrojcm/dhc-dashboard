import type { Plugin } from "@opencode-ai/plugin";

/**
 * Git Guardian
 *
 * Blocks the agent from invoking any `git` command in the `bash` tool.
 * Git operations should be performed through GitButler (`but`) instead.
 */
export default (async ({ client }) => {
  await client.app.log({
    body: {
      service: "git-guardian",
      level: "info",
      message: "Git Guardian plugin initialized",
    },
  });

  return {
    "tool.execute.before": async (input, output) => {
      if (
        input.tool !== "bash" ||
        !output.args ||
        typeof output.args.command !== "string"
      ) {
        return;
      }

      const command = output.args.command.trim();

      // Match `git` as the first word or after common shell separators/prefixes.
      // Catches direct invocations like `git status`, `git add ...`,
      // and shell constructs like `cd foo && git log`.
      const gitPattern = /(^|&&|;|\|\||`|\$\()\s*git\b/;

      if (gitPattern.test(command)) {
        await client.app.log({
          body: {
            service: "git-guardian",
            level: "warn",
            message: "Blocked git command",
            extra: { command: command.slice(0, 200) },
          },
        });

        throw new Error(
          "Direct `git` commands are not allowed. Use GitButler (`but`) instead.\n" +
            "Run `but --help` or `but diff` to get started.\n" +
            "See the `but` skill for common workflows.",
        );
      }
    },
  };
}) satisfies Plugin;
