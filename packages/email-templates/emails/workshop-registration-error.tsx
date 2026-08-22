import type { TemplateMetadata } from "../src/template-metadata";

import { EmailLayout, SignOff, paragraphStyle } from "./_components/layout";
import { Text } from "react-email";
import { defineTemplate } from "../src/template-metadata";

export interface WorkshopRegistrationErrorProps {
  /** Title of the workshop whose registration could not be confirmed. */
  WORKSHOP_NAME: string;
}

export const workshopRegistrationErrorTemplate: TemplateMetadata = defineTemplate({
  kind: "workshopRegistrationError",
  subject: "Your DHC workshop registration could not be confirmed",
  from: "Dublin HEMA Club <info@dublinhemaclub.com>",
  variables: [{ key: "WORKSHOP_NAME", type: "string" }],
});

/** Ported verbatim from the Loops `workshopRegistrationError` transactional template. */
export default function WorkshopRegistrationErrorEmail({
  WORKSHOP_NAME,
}: WorkshopRegistrationErrorProps) {
  return (
    <EmailLayout
      heading="Registration Problem"
      preview="Your DHC workshop registration could not be confirmed"
    >
      <Text style={paragraphStyle}>Hi there,</Text>
      <Text style={paragraphStyle}>
        Unfortunately, your registration for the workshop {WORKSHOP_NAME} could not be confirmed due
        to error. Your payment has been refunded.
      </Text>
      <SignOff close="Best" />
    </EmailLayout>
  );
}

WorkshopRegistrationErrorEmail.PreviewProps = {
  WORKSHOP_NAME: "Longsword Fundamentals",
} satisfies WorkshopRegistrationErrorProps;
