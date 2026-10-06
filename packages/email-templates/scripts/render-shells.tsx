/**
 * Shell render pipeline for broadcast emails (ADR 0028).
 *
 * Broadcast bodies are rich text that cannot travel through a Resend
 * template variable (2,000-character limit, unspecified escaping), so the
 * React Email component is rendered **once** with literal `{{{PLACEHOLDER}}}`
 * markers into a committed HTML shell that Phoenix fills and sends inline.
 *
 *   tsx scripts/render-shells.tsx   rewrite every shell under
 *                                   apps/phoenix/priv/email_shells/
 *
 * `test/render-shells.test.ts` fails when a committed shell no longer matches
 * a fresh render, so a template edit cannot ship without its shell.
 */

import { writeFile } from "node:fs/promises";
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

async function main(): Promise<number> {
  for (const artifact of await renderShells()) {
    await writeFile(new URL(artifact.file, pathToFileURL(SHELLS_DIR)), artifact.contents);
    console.log(`✓ ${artifact.file}`);
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
