import { readFile } from "node:fs/promises";

import { describe, expect, it } from "vitest";

import { renderShells, SHELLS_DIR } from "../scripts/render-shells";

/**
 * Phoenix compiles the committed shells in (ADR 0028), so a template edit
 * must be followed by `pnpm render:shells`. This is the drift guard.
 */
describe("broadcast email shells", () => {
  it("match a fresh render (run `pnpm render:shells` after editing a shell template)", async () => {
    for (const artifact of await renderShells()) {
      const committed = await readFile(new URL(artifact.file, `file://${SHELLS_DIR}`), "utf8");
      expect(committed, artifact.file).toBe(artifact.contents);
    }
  });

  it("keeps the placeholders Phoenix fills and an absolute crest URL", async () => {
    const [shell] = await renderShells();

    expect(shell?.contents).toContain("{{{SUBJECT}}}");
    expect(shell?.contents).toContain("{{{MESSAGE_HTML}}}");
    expect(shell?.contents).not.toContain('src="/static/');
  });
});
