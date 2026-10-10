import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { render } from "react-email";
import InviteMemberEmail, { inviteMemberTemplate } from "../emails/invite-member";

import { renderTemplateHtml } from "../scripts/sync";

const SITE = "https://dashboard.dublinhemaclub.com";

/**
 * The uploaded HTML must keep Resend's {{{VAR}}} interpolation markers (not
 * sample data), so the provider substitutes real values at send time. These
 * renders exercise the exact code path the sync pipeline uploads through.
 */
describe("renderTemplateHtml", () => {
  it("uses the supplied insurance URL in the invitation email", async () => {
    const insuranceLink = "https://insurance.example.com/onboarding.html";
    const html = await render(
      createElement(InviteMemberEmail, {
        INVITATION_LINK: `${SITE}/members/signup/example`,
        INSURANCE_FORM_LINK: insuranceLink,
      }),
    );

    expect(html).toContain(`href="${insuranceLink}"`);
  });

  it("keeps the original insurance destination when no setting is supplied", async () => {
    const html = await render(
      createElement(InviteMemberEmail, {
        INVITATION_LINK: `${SITE}/members/signup/example`,
      }),
    );

    expect(html).toContain('href="https://www.hemaireland.com/"');
    expect(inviteMemberTemplate.variables).toContainEqual({
      key: "INSURANCE_FORM_LINK",
      type: "string",
      fallback: "https://www.hemaireland.com/",
    });
  });

  it("renders the configured insurance form link placeholder", async () => {
    const html = await renderTemplateHtml("inviteMember", SITE);

    expect(html).toContain('href="{{{INSURANCE_FORM_LINK}}}"');
    expect(html).not.toContain('href="https://www.hemaireland.com/"');
  });

  it("renders magic-link with the LOGIN_LINK placeholder intact", async () => {
    const html = await renderTemplateHtml("magicLink", SITE);

    expect(html).toContain('href="{{{LOGIN_LINK}}}"');
    expect(html).not.toContain("token=preview");
  });

  it("renders workshop-announcement placeholders for rendered variables", async () => {
    const html = await renderTemplateHtml("workshopAnnouncement", SITE);

    expect(html).toContain("{{{MEMBER_FIRST_NAME}}}");
    expect(html).toContain("{{{MESSAGE}}}");
  });

  it("renders the Beginners' Workshop action email with its message, link and label", async () => {
    const html = await renderTemplateHtml("beginnersWorkshopAction", SITE);

    expect(html).toContain("{{{MESSAGE_HTML}}}");
    expect(html).toContain('href="{{{BUTTON_URL}}}"');
    expect(html).toContain("{{{BUTTON_LABEL}}}");
  });

  it("renders the Beginners' Workshop notice email with its message and no button", async () => {
    const html = await renderTemplateHtml("beginnersWorkshopNotice", SITE);

    expect(html).toContain("{{{MESSAGE_HTML}}}");
    expect(html).not.toContain("BUTTON_URL");
  });

  it("styles the unstyled Beginners' Workshop body from a scoped stylesheet", async () => {
    const html = await renderTemplateHtml("beginnersWorkshopNotice", SITE);

    expect(html).toMatch(/<style>[^<]*\.dhc-message p\{[^}]*margin:0 0 20px/);
    expect(html).toContain('"Calistoga"');
    expect(html).toContain('class="dhc-message"');
  });

  it("rewrites the crest to its hosted absolute URL", async () => {
    const html = await renderTemplateHtml("inviteMember", SITE);

    expect(html).toContain(`src="${SITE}/logo.png"`);
    expect(html).not.toContain('src="/static/');
    expect(html).toContain('href="{{{INVITATION_LINK}}}"');
  });
});
