import type { TemplateMetadata } from "../src/template-metadata";

import { EmailLayout, Mark, SignOff, linkStyle, paragraphStyle } from "./_components/layout";
import { Link, Text } from "react-email";
import { defineTemplate } from "../src/template-metadata";

/**
 * Where the "items" link in the original Loops `inviteMember` template
 * points: HEMA Ireland, the third-party liability insurance provider.
 */
const HEMA_IRELAND_ITEMS_URL = "https://www.hemaireland.com/";

export interface InviteMemberProps {
  /** The recipient's unique invitation acceptance link. */
  INVITATION_LINK: string;
  /**
   * Declared because callers send them alongside the link; the original
   * Loops template greets the recipient with a plain "Hello," and never
   * renders the names.
   */
  INVITEE_FIRST_NAME?: string;
  INVITEE_LAST_NAME?: string;
}

export const inviteMemberTemplate: TemplateMetadata = defineTemplate({
  kind: "inviteMember",
  subject: "You're invited to join Dublin HEMA Club",
  from: "Dublin HEMA Club <info@dublinhemaclub.com>",
  variables: [
    { key: "INVITEE_FIRST_NAME", type: "string", fallback: "" },
    { key: "INVITEE_LAST_NAME", type: "string", fallback: "" },
    { key: "INVITATION_LINK", type: "string" },
  ],
});

/** Ported verbatim from the Loops `inviteMember` transactional template. */
export default function InviteMemberEmail({ INVITATION_LINK }: InviteMemberProps) {
  return (
    <EmailLayout
      heading={
        <>
          You're invited to join <Mark>DHC</Mark>
        </>
      }
      preview="You have been invited to join Dublin HEMA Club"
    >
      <Text style={paragraphStyle}>Hello,</Text>
      <Text style={paragraphStyle}>
        You have been invited to join DHC. Please follow{" "}
        <Link href={INVITATION_LINK} style={linkStyle}>
          this
        </Link>{" "}
        link and fill in your details. This link expires in 7 days, so please make sure you fill it
        out before that!
      </Text>
      <Text style={paragraphStyle}>
        Additionally, please purchase the following{" "}
        <Link href={HEMA_IRELAND_ITEMS_URL} style={linkStyle}>
          items
        </Link>{" "}
        from HEMA Ireland. This third-party liability insurance covers damages to third parties,
        items damaged in the sports hall during training, etc. It is not health or injury insurance;
        we encourage our members to get personal health insurance if they so wish.
      </Text>
      <SignOff />
    </EmailLayout>
  );
}

InviteMemberEmail.PreviewProps = {
  INVITATION_LINK: "https://dashboard.dublinhemaclub.com/invitations/accept?token=preview",
} satisfies InviteMemberProps;
