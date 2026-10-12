import type { TemplateMetadata } from "../src/template-metadata";

import { Button } from "react-email";

import { EmailLayout, buttonStyle } from "./_components/layout";
import { RichMessage, richMessageCss } from "./_components/rich-message";
import { defineTemplate } from "../src/template-metadata";

/**
 * Beginners' Workshop Intake Email with a button (ALE-377), for open Intakes:
 * contact, place confirmed, pre-workshop info and rescheduled.
 *
 * The copy is not authored here. Each email type has one club-wide template
 * (subject and Tiptap body) that the coordinator edits in the dashboard;
 * Phoenix fills its placeholders when the email is queued and passes:
 *
 * - `MESSAGE_HTML`: the rendered body, every text node and placeholder value
 *   HTML-escaped, with no per-element inline styles. The first name is part
 *   of it because Resend reserves `FIRST_NAME`.
 * - `BUTTON_URL`: the person's Intake link. It is a credential, so it travels
 *   sealed and never appears in job args in plaintext.
 * - `BUTTON_LABEL`: set by the app for the Intake's state ("Pay for your place").
 *
 * The subject is passed per send and overrides the default below.
 */
export interface BeginnersWorkshopActionProps {
  MESSAGE_HTML: string;
  BUTTON_URL: string;
  BUTTON_LABEL: string;
}

export const beginnersWorkshopActionTemplate: TemplateMetadata = defineTemplate({
  kind: "beginnersWorkshopAction",
  subject: "Your Dublin HEMA Club Beginners' Workshop",
  from: "Dublin HEMA Club <info@dublinhemaclub.com>",
  variables: [
    { key: "MESSAGE_HTML", type: "string" },
    { key: "BUTTON_URL", type: "string" },
    { key: "BUTTON_LABEL", type: "string", fallback: "View my place" },
  ],
});

export default function BeginnersWorkshopActionEmail({
  MESSAGE_HTML,
  BUTTON_URL,
  BUTTON_LABEL,
}: BeginnersWorkshopActionProps) {
  return (
    <EmailLayout headCss={richMessageCss()} preview="Your Dublin HEMA Club Beginners' Workshop">
      <RichMessage html={MESSAGE_HTML} />
      <Button href={BUTTON_URL} style={buttonStyle}>
        {BUTTON_LABEL}
      </Button>
    </EmailLayout>
  );
}

BeginnersWorkshopActionEmail.PreviewProps = {
  MESSAGE_HTML: [
    "<p>Hi Aoife,</p>",
    "<p>Good news: you're near the top of our waitlist, and we'd love to see you at our next Beginners' Workshop on <strong>Saturday 14 November at 10:00</strong>, at St. Michan's Hall. The fee is €50.00.</p>",
    "<p>Our waitlist is long, so please pay by <strong>Sunday 8 November, 23:59</strong>.</p>",
    "<p>See you on the floor,<br>Dublin HEMA Club</p>",
  ].join(""),
  BUTTON_URL: "https://dashboard.dublinhemaclub.com/beginners/intake/preview",
  BUTTON_LABEL: "Pay for your place",
} satisfies BeginnersWorkshopActionProps;
