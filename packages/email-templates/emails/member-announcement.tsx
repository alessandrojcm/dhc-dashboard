import { EmailLayout, SignOff } from "./_components/layout";
import { MESSAGE_STYLES } from "./_components/message-styles";

/**
 * Member Announcement — a committee email to many members at once (ADR 0028).
 *
 * Unlike the transactional templates this is **not** a Resend-hosted
 * template and not an Email Kind: its body is rich text that can exceed
 * Resend's 2,000-character variable limit. Instead `scripts/render-shells.tsx`
 * renders this component before Phoenix compilation with literal `{{{SUBJECT}}}` /
 * `{{{MESSAGE_HTML}}}` placeholders into
 * `apps/phoenix/priv/email_shells/member-announcement.html`. Phoenix fills the
 * placeholders — the subject HTML-escaped, the body rendered from a closed
 * Tiptap vocabulary — and sends the result as inline `html`. The dashboard
 * preview is that same Phoenix render, so the preview is the email.
 *
 * Recipients are BCC'd, so there is deliberately no per-recipient greeting.
 */
export interface MemberAnnouncementProps {
  /** The email subject; also shown as the heading and preheader. */
  SUBJECT: string;
  /** The rendered, already-safe announcement body HTML. */
  MESSAGE_HTML: string;
}

export const MEMBER_ANNOUNCEMENT_PLACEHOLDERS = ["SUBJECT", "MESSAGE_HTML"] as const;

export default function MemberAnnouncementEmail({
  SUBJECT,
  MESSAGE_HTML,
}: MemberAnnouncementProps) {
  return (
    <EmailLayout heading={SUBJECT} preview={SUBJECT}>
      {/* The body is HTML Phoenix rendered from a closed vocabulary. */}
      <div dangerouslySetInnerHTML={{ __html: MESSAGE_HTML }} />
      <SignOff />
    </EmailLayout>
  );
}

MemberAnnouncementEmail.PreviewProps = {
  SUBJECT: "Annual General Meeting",
  MESSAGE_HTML: [
    `<p style='${MESSAGE_STYLES.p}'>Hello everyone,</p>`,
    `<p style='${MESSAGE_STYLES.p}'>Our <strong style='${MESSAGE_STYLES.strong}'>AGM</strong> takes place on Thursday 12 November at 19:30 in St. Michan's Hall.</p>`,
    `<h2 style='${MESSAGE_STYLES.h2}'>Agenda</h2>`,
    `<ul style='${MESSAGE_STYLES.ul}'><li style='${MESSAGE_STYLES.li}'>Committee reports</li><li style='${MESSAGE_STYLES.li}'>Elections</li></ul>`,
    `<p style='${MESSAGE_STYLES.p}'>Read the <a style='${MESSAGE_STYLES.a}' href='https://dublinhemaclub.com'>full notice</a>.</p>`,
  ].join(""),
} satisfies MemberAnnouncementProps;
