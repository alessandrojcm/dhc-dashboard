import { describe, expect, it } from "vitest";

import { getTemplate } from "../src/index";
import { absolutizeAssets, findUnpublished, placeholderProps } from "../scripts/sync";

describe("placeholderProps", () => {
  it("maps every declared variable to its triple-brace placeholder", () => {
    expect(placeholderProps(getTemplate("magicLink"))).toEqual({
      LOGIN_LINK: "{{{LOGIN_LINK}}}",
    });
  });

  it("covers variables with fallbacks too", () => {
    expect(placeholderProps(getTemplate("workshopAnnouncement"))).toEqual({
      MEMBER_FIRST_NAME: "{{{MEMBER_FIRST_NAME}}}",
      MEMBER_LAST_NAME: "{{{MEMBER_LAST_NAME}}}",
      MESSAGE: "{{{MESSAGE}}}",
      WORKSHOP_COUNT: "{{{WORKSHOP_COUNT}}}",
    });
  });
});

describe("absolutizeAssets", () => {
  it("rewrites relative /static/ sources onto the club site", () => {
    const html = '<img alt="crest" src="/static/logo.png" />';
    expect(absolutizeAssets(html, "https://dashboard.dublinhemaclub.com")).toBe(
      '<img alt="crest" src="https://dashboard.dublinhemaclub.com/logo.png" />',
    );
  });

  it("leaves absolute URLs untouched", () => {
    const html = '<img src="https://cdn.example.com/pic.png" />';
    expect(absolutizeAssets(html, "https://dashboard.dublinhemaclub.com")).toBe(html);
  });
});

describe("findUnpublished", () => {
  const kinds = ["magicLink", "inviteMember"] as const;

  it("passes when every kind resolves to a published template", () => {
    const remote = [
      { alias: "magic-link", status: "published" },
      { alias: "invite-member", status: "published" },
    ] as const;
    expect(findUnpublished(kinds, remote)).toEqual([]);
  });

  it("flags a kind whose template is missing entirely (typo'd alias guard)", () => {
    const remote = [{ alias: "magic-link", status: "published" }] as const;
    expect(findUnpublished(kinds, remote)).toEqual(["inviteMember"]);
  });

  it("flags a kind whose latest version is only a draft", () => {
    const remote = [
      { alias: "magic-link", status: "published" },
      { alias: "invite-member", status: "draft" },
    ] as const;
    expect(findUnpublished(kinds, remote)).toEqual(["inviteMember"]);
  });

  it("ignores templates outside the whitelist", () => {
    const remote = [{ alias: "some-other-template", status: "published" }] as const;
    expect(findUnpublished(kinds, remote)).toEqual([...kinds]);
  });
});
