import type { TemplateMetadata } from "../src/template-metadata";

import { EmailLayout, SignOff, paragraphStyle } from "./_components/layout";
import { Text } from "react-email";
import { defineTemplate } from "../src/template-metadata";

export interface WorkshopAnnouncementProps {
  /**
   * The formatted announcement body produced by
   * `Dhc.WorkshopAnnouncements.format_email_message/2`; may contain
   * newlines and bullet lines.
   */
  MESSAGE: string;
  /** Greet the recipient by first name; falls back to a neutral greeting. */
  MEMBER_FIRST_NAME?: string;
  /**
   * Declared because callers send it alongside the first name; the body
   * does not render it.
   */
  MEMBER_LAST_NAME?: string;
  /** Number of workshops covered; declared for caller parity, not rendered. */
  WORKSHOP_COUNT?: number;
}

export const workshopAnnouncementTemplate: TemplateMetadata = defineTemplate({
  kind: "workshopAnnouncement",
  subject: "Dublin HEMA Club Workshop Update",
  from: "Dublin HEMA Club <no-reply@mail.dublinhemaclub.com>",
  variables: [
    { key: "MEMBER_FIRST_NAME", type: "string", fallback: "there" },
    { key: "MEMBER_LAST_NAME", type: "string", fallback: "" },
    { key: "MESSAGE", type: "string" },
    { key: "WORKSHOP_COUNT", type: "number", fallback: 0 },
  ],
});

/**
 * Drafted port of the Loops `workshopAnnouncement` transactional template
 * (the original content was not exported before the migration). The body is
 * built around the message text the announcement worker already formats.
 */
export default function WorkshopAnnouncementEmail({
  MESSAGE,
  MEMBER_FIRST_NAME,
}: WorkshopAnnouncementProps) {
  return (
    <EmailLayout heading="Workshop Update" preview="A Dublin HEMA Club workshop update">
      <Text style={paragraphStyle}>Hello {MEMBER_FIRST_NAME},</Text>
      <Text style={{ ...paragraphStyle, whiteSpace: "pre-line" }}>{MESSAGE}</Text>
      <SignOff />
    </EmailLayout>
  );
}

WorkshopAnnouncementEmail.PreviewProps = {
  MESSAGE:
    'Registration Now Open: Longsword Fundamentals on March 15, 2026 at 7:00 PM at St. Michan\'s Hall. Head to "My Workshops" to register!',
  MEMBER_FIRST_NAME: "Aoife",
} satisfies WorkshopAnnouncementProps;
