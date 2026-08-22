import { describe, expect, it } from "vitest";

import { EMAIL_KINDS, defineTemplate, templateAlias } from "../src/template-metadata";

describe("templateAlias", () => {
  it.each([
    ["inviteMember", "invite-member"],
    ["workshopAnnouncement", "workshop-announcement"],
    ["workshopRegistration", "workshop-registration"],
    ["workshopRegistrationError", "workshop-registration-error"],
    ["magicLink", "magic-link"],
  ])("derives the kebab-case alias of %s", (kind, expected) => {
    expect(templateAlias(kind)).toBe(expected);
  });
});

describe("defineTemplate", () => {
  const valid = {
    kind: "inviteMember",
    subject: "You are invited",
    from: "Dublin HEMA Club <no-reply@mail.dublinhemaclub.com>",
    variables: [{ key: "INVITATION_LINK", type: "string" }],
  } as const;

  it("derives and attaches the alias from the Email Kind", () => {
    const template = defineTemplate(valid);
    expect(template.alias).toBe("invite-member");
  });

  it("exposes subject, sender, and variables untouched", () => {
    const template = defineTemplate(valid);
    expect(template.subject).toBe("You are invited");
    expect(template.from).toContain("@");
    expect(template.variables).toHaveLength(1);
  });

  it("returns frozen metadata so definitions cannot drift after import", () => {
    const template = defineTemplate(valid);
    expect(Object.isFrozen(template)).toBe(true);
  });

  it("accepts number-typed variables with matching fallbacks", () => {
    const template = defineTemplate({
      ...valid,
      variables: [{ key: "WORKSHOP_COUNT", type: "number", fallback: 0 }],
    });
    expect(template.variables[0]?.fallback).toBe(0);
  });

  // The fallback/type correlation and the Email Kind whitelist are enforced
  // at compile time: TemplateVariable is a discriminated union and `kind` is
  // the EMAIL_KINDS literal union, so invalid pairings cannot be expressed
  // in TypeScript. Resend re-validates both contracts at send time.

  it("rejects a key that is not UPPER_SNAKE", () => {
    expect(() =>
      defineTemplate({
        ...valid,
        variables: [{ key: "invitationLink", type: "string" }],
      }),
    ).toThrow(/UPPER_SNAKE/);
  });

  it.each(["FIRST_NAME", "LAST_NAME", "EMAIL", "RESEND_UNSUBSCRIBE_URL"])(
    "rejects Resend reserved name %s case-insensitively",
    (key) => {
      expect(() =>
        defineTemplate({
          ...valid,
          variables: [{ key, type: "string" }],
        }),
      ).toThrow(/reserved by Resend/);
    },
  );

  it("rejects more than 20 declared variables", () => {
    const variables = Array.from({ length: 21 }, (_, i) => ({
      key: `VARIABLE_${i}`,
      type: "string" as const,
    }));

    expect(() => defineTemplate({ ...valid, variables })).toThrow(/at most 20/);
  });

  it("rejects duplicate variable keys", () => {
    expect(() =>
      defineTemplate({
        ...valid,
        variables: [
          { key: "MESSAGE", type: "string" },
          { key: "MESSAGE", type: "number" },
        ],
      }),
    ).toThrow(/duplicate/);
  });

  it("rejects empty subject or sender", () => {
    expect(() => defineTemplate({ ...valid, subject: "" })).toThrow(/subject/);
    expect(() => defineTemplate({ ...valid, from: "no address here" })).toThrow(/from/);
  });
});

describe("EMAIL_KINDS whitelist", () => {
  it("mirrors the five whitelisted kinds of Dhc.Email.Worker", () => {
    expect([...EMAIL_KINDS]).toEqual([
      "inviteMember",
      "workshopAnnouncement",
      "workshopRegistration",
      "workshopRegistrationError",
      "magicLink",
    ]);
  });
});
