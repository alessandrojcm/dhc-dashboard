import { describe, expect, it } from "vitest";

import { renderTemplateHtml } from "../scripts/sync";

const SITE = "https://dashboard.dublinhemaclub.com";

/**
 * The uploaded HTML must keep Resend's {{{VAR}}} interpolation markers (not
 * sample data), so the provider substitutes real values at send time. These
 * renders exercise the exact code path the sync pipeline uploads through.
 */
describe("renderTemplateHtml", () => {
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

  it("rewrites the crest to its hosted absolute URL", async () => {
    const html = await renderTemplateHtml("inviteMember", SITE);

    expect(html).toContain(`src="${SITE}/logo.png"`);
    expect(html).not.toContain('src="/static/');
    expect(html).toContain('href="{{{INVITATION_LINK}}}"');
  });
});
