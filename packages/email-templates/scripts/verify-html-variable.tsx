/**
 * One-off verification for the Beginners' Workshop Intake Emails (ALE-377):
 * does Resend insert a `{{{VARIABLE}}}` value **unescaped**? Resend's docs do
 * not say, and Mailpit only shows the worker's JSON summary, so nothing that
 * relies on `MESSAGE_HTML` should ship before this passes once.
 *
 *   RESEND_API_KEY=<Full Access key> pnpm --filter @dhc/email-templates verify:html-variable
 *
 * It renders the real `beginnersWorkshopNotice` component, uploads it under a
 * throwaway alias, publishes it, sends one email to Resend's test inbox
 * (`delivered@resend.dev`) with an HTML `MESSAGE_HTML` value and a subject
 * override (as `Dhc.Email.Worker` does), reads the delivered HTML back
 * through the API, and removes the throwaway template again. Exit code 0
 * means the markup arrived as markup and the subject override applied.
 */

import { pathToFileURL } from "node:url";

import { Resend } from "resend";

import { beginnersWorkshopNoticeTemplate } from "../emails/beginners-workshop-notice";
import { DEFAULT_ASSETS_BASE_URL, renderTemplateHtml } from "./sync";

const ALIAS = "beginners-workshop-notice-html-check";
const TO = "delivered@resend.dev";
const SUBJECT = "Intake Email HTML variable check";
/** The shape Phoenix sends: escaped text inside real markup. */
const MESSAGE_HTML =
  "<p>Hi O&#39;Brien,</p><p><strong>Bold</strong> &amp; <em>italic</em> &lt;not a tag&gt;</p>";

export type HtmlVariableVerdict = "unescaped" | "escaped" | "missing";

/** Classifies the delivered HTML: was the variable inserted as markup? */
export function classifyDeliveredHtml(html: string): HtmlVariableVerdict {
  if (html.includes("<strong>Bold</strong>") && html.includes("&lt;not a tag&gt;")) {
    return "unescaped";
  }
  if (html.includes("&lt;strong&gt;Bold")) return "escaped";
  return "missing";
}

function fail(message: string): never {
  throw new Error(message);
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function main(): Promise<number> {
  const apiKey = process.env.RESEND_API_KEY ?? fail("RESEND_API_KEY (Full Access) is not set");
  const resend = new Resend(apiKey);

  const html = await renderTemplateHtml("beginnersWorkshopNotice", DEFAULT_ASSETS_BASE_URL);
  const created = await resend.templates.create({
    name: `${ALIAS} (temporary)`,
    alias: ALIAS,
    subject: beginnersWorkshopNoticeTemplate.subject,
    from: beginnersWorkshopNoticeTemplate.from,
    html,
    variables: [{ key: "MESSAGE_HTML", type: "string" }],
  });
  const templateId = created.data?.id ?? fail(`Create failed: ${created.error?.message}`);

  try {
    const published = await resend.templates.publish(templateId);
    if (published.error) fail(`Publish failed: ${published.error.message}`);

    const sent = await resend.emails.send({
      to: TO,
      subject: SUBJECT,
      template: { id: ALIAS, variables: { MESSAGE_HTML } },
    });
    const emailId = sent.data?.id ?? fail(`Send failed: ${sent.error?.message}`);
    console.log(`Sent ${emailId} to ${TO}`);

    for (let attempt = 0; attempt < 10; attempt++) {
      const fetched = await resend.emails.get(emailId);
      const delivered = fetched.data;
      if (delivered?.html) {
        const verdict = classifyDeliveredHtml(delivered.html);
        console.log(`MESSAGE_HTML was inserted: ${verdict}`);
        console.log(`Subject: ${delivered.subject}`);
        return verdict === "unescaped" && delivered.subject === SUBJECT ? 0 : 1;
      }
      await sleep(2_000);
    }
    fail("The sent email's HTML never became available");
  } finally {
    await resend.templates.remove(templateId);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
