import type { TemplateMetadata } from "../src/template-metadata";

import { EmailLayout, Mark, SignOff, buttonStyle, paragraphStyle } from "./_components/layout";
import { Button, Text } from "react-email";
import { defineTemplate } from "../src/template-metadata";

/**
 * Matches `@magic_link_validity_in_minutes` in `Dhc.Auth.PrincipalToken`;
 * the two must stay in sync because the copy tells the recipient how long
 * the link works.
 */
const MAGIC_LINK_VALIDITY_IN_MINUTES = 15;

export interface MagicLinkProps {
  /** The single-use sign-in link. */
  LOGIN_LINK: string;
}

export const magicLinkTemplate: TemplateMetadata = defineTemplate({
  kind: "magicLink",
  subject: "Your Dublin HEMA Club login link",
  from: "Dublin HEMA Club <no-reply@mail.dublinhemaclub.com>",
  variables: [{ key: "LOGIN_LINK", type: "string" }],
});

/**
 * Inferred port of the Loops `magicLink` transactional template (the
 * original content was not exported before the migration): a single-use,
 * 15-minute sign-in link.
 */
export default function MagicLinkEmail({ LOGIN_LINK }: MagicLinkProps) {
  return (
    <EmailLayout
      heading={
        <>
          Log in to <Mark>DHC</Mark>
        </>
      }
      preview="Your Dublin HEMA Club sign-in link"
    >
      <Text style={paragraphStyle}>Hi there,</Text>
      <Text style={paragraphStyle}>
        Use the button below to sign in to your Dublin HEMA Club account:
      </Text>
      <Button href={LOGIN_LINK} style={buttonStyle}>
        Log in
      </Button>
      <Text style={paragraphStyle}>
        This link expires in {MAGIC_LINK_VALIDITY_IN_MINUTES} minutes and can only be used once. If
        you didn't request it, you can safely ignore this email.
      </Text>
      <SignOff />
    </EmailLayout>
  );
}

MagicLinkEmail.PreviewProps = {
  LOGIN_LINK: "https://dashboard.dublinhemaclub.com/auth/magic-link/consume?token=preview",
} satisfies MagicLinkProps;
