import type { TemplateMetadata } from "../src/template-metadata";

import { EmailLayout } from "./_components/layout";
import { RichMessage, richMessageCss } from "./_components/rich-message";
import { defineTemplate } from "../src/template-metadata";

/**
 * Beginners' Workshop Intake Email without a button (ALE-377), for closed
 * Intakes, whose link would only say "no longer active": follow-up, declined,
 * deferred, refunds, withdrawals and cancellations.
 *
 * `MESSAGE_HTML` is the club-wide template for the email type, rendered and
 * filled by Phoenix when the email is queued (see
 * `beginners-workshop-action.tsx`). The subject is passed per send.
 */
export interface BeginnersWorkshopNoticeProps {
  MESSAGE_HTML: string;
}

export const beginnersWorkshopNoticeTemplate: TemplateMetadata = defineTemplate({
  kind: "beginnersWorkshopNotice",
  subject: "Your Dublin HEMA Club Beginners' Workshop",
  from: "Dublin HEMA Club <info@dublinhemaclub.com>",
  variables: [{ key: "MESSAGE_HTML", type: "string" }],
});

export default function BeginnersWorkshopNoticeEmail({
  MESSAGE_HTML,
}: BeginnersWorkshopNoticeProps) {
  return (
    <EmailLayout headCss={richMessageCss()} preview="An update about your Beginners' Workshop">
      <RichMessage html={MESSAGE_HTML} />
    </EmailLayout>
  );
}

BeginnersWorkshopNoticeEmail.PreviewProps = {
  MESSAGE_HTML:
    "<p>Hi Aoife,</p><p>Thanks for coming on <strong>Saturday 14 November</strong>! Your first regular class is free.</p><p>Dublin HEMA Club</p>",
} satisfies BeginnersWorkshopNoticeProps;
