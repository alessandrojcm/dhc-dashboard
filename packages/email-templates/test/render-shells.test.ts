import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { renderShells, writeShells } from "../scripts/render-shells";
import { MESSAGE_STYLES } from "../emails/_components/message-styles";

/**
 * Phoenix compiles generated shells in (ADR 0028). Verify generation from
 * a missing directory and repeated writes without needing committed artifacts.
 */
describe("broadcast email shells", () => {
  it("writes both artifacts to a missing directory and regenerates them deterministically", async () => {
    const temp = await mkdtemp(join(tmpdir(), "email-shells-"));
    const output = join(temp, "priv", "email_shells");
    try {
      const artifacts = await renderShells();
      expect(artifacts.map(({ file }) => file)).toEqual([
        "member-announcement.html",
        "member-announcement.styles.json",
      ]);
      for (let pass = 0; pass < 2; pass++) {
        await writeShells(output);
        for (const artifact of artifacts) {
          expect(await readFile(join(output, artifact.file), "utf8"), artifact.file).toBe(
            artifact.contents,
          );
        }
      }
      expect(
        JSON.parse(await readFile(join(output, "member-announcement.styles.json"), "utf8")),
      ).toEqual(MESSAGE_STYLES);
    } finally {
      await rm(temp, { recursive: true, force: true });
    }
  });

  it("keeps the placeholders Phoenix fills and an absolute crest URL", async () => {
    const [shell] = await renderShells();

    expect(shell?.contents).toContain("{{{SUBJECT}}}");
    expect(shell?.contents).toContain("{{{MESSAGE_HTML}}}");
    expect(shell?.contents).not.toContain('src="/static/');
  });
});
