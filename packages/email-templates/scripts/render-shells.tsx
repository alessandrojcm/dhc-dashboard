/**
 * Shell render pipeline for broadcast emails (ADR 0028).
 *
 * Broadcast bodies are rich text that cannot travel through a Resend
 * template variable (2,000-character limit, unspecified escaping), so the
 * React Email component is rendered **once** with literal `{{{PLACEHOLDER}}}`
 * markers into a gitignored HTML shell that Phoenix fills and sends inline.
 *
 *   tsx scripts/render-shells.tsx   rewrite every shell under
 *                                   apps/phoenix/priv/email_shells/
 *
 * Generate before Phoenix compilation or uploading the Fly build context.
 * The generated HTML and style table ship together in the Phoenix release.
 */

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { render } from "react-email";

import MemberAnnouncementEmail, {
  MEMBER_ANNOUNCEMENT_PLACEHOLDERS,
} from "../emails/member-announcement";
import { MESSAGE_STYLES } from "../emails/_components/message-styles";
import { absolutizeAssets, DEFAULT_ASSETS_BASE_URL } from "./sync";

/** Where Phoenix reads the shells from at compile time. */
export const SHELLS_DIR = fileURLToPath(
  new URL("../../../apps/phoenix/priv/email_shells/", import.meta.url),
);

export interface ShellArtifact {
  /** File name relative to {@link SHELLS_DIR}. */
  readonly file: string;
  readonly contents: string;
}

function placeholder(key: string): string {
  return `{{{${key}}}}`;
}

/** Renders every shell artifact (HTML + its style table) in memory. */
export async function renderShells(
  assetsBaseUrl: string = DEFAULT_ASSETS_BASE_URL,
): Promise<ShellArtifact[]> {
  const [subject, message] = MEMBER_ANNOUNCEMENT_PLACEHOLDERS.map(placeholder);
  const html = await render(
    <MemberAnnouncementEmail SUBJECT={subject ?? ""} MESSAGE_HTML={message ?? ""} />,
  );

  return [
    {
      file: "member-announcement.html",
      contents: absolutizeAssets(html, assetsBaseUrl),
    },
    {
      file: "member-announcement.styles.json",
      contents: `${JSON.stringify(MESSAGE_STYLES, null, 2)}\n`,
    },
  ];
}

/** Creates the output directory even on a clean checkout. */
export async function writeShells(outputDir: string = SHELLS_DIR): Promise<void> {
  await mkdir(outputDir, { recursive: true });
  for (const artifact of await renderShells()) {
    await writeFile(join(outputDir, artifact.file), artifact.contents);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await writeShells();
}
