import type { TemplateMetadata } from "../src/template-metadata";

import { EmailLayout, SignOff, paragraphStyle } from "./_components/layout";
import { Text } from "react-email";
import { defineTemplate } from "../src/template-metadata";

export interface WorkshopRegistrationProps {
  /** Title of the workshop the member registered for. */
  WORKSHOP_NAME: string;
}

export const workshopRegistrationTemplate: TemplateMetadata = defineTemplate({
  kind: "workshopRegistration",
  subject: "Your DHC workshop registration is confirmed",
  from: "Dublin HEMA Club <info@dublinhemaclub.com>",
  variables: [{ key: "WORKSHOP_NAME", type: "string" }],
});

/**
 * Drafted port of the Loops `workshopRegistration` transactional template
 * (the original content was not exported and no production path enqueues
 * this kind yet — it is a reserved name). Tone mirrors the error variant.
 */
export default function WorkshopRegistrationEmail({ WORKSHOP_NAME }: WorkshopRegistrationProps) {
  return (
    <EmailLayout
      heading="Registration Confirmed"
      preview="Your DHC workshop registration is confirmed"
    >
      <Text style={paragraphStyle}>Hi there,</Text>
      <Text style={paragraphStyle}>
        Your registration for the workshop {WORKSHOP_NAME} has been confirmed. We look forward to
        seeing you there!
      </Text>
      <SignOff close="Best" />
    </EmailLayout>
  );
}

WorkshopRegistrationEmail.PreviewProps = {
  WORKSHOP_NAME: "Longsword Fundamentals",
} satisfies WorkshopRegistrationProps;
