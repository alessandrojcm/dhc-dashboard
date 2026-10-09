import { describe, expect, it } from "vitest";

import { classifyDeliveredHtml } from "../scripts/verify-html-variable";

describe("classifyDeliveredHtml", () => {
  it("passes when the markup arrived as markup and escaped text stayed escaped", () => {
    expect(
      classifyDeliveredHtml(
        "<div><p><strong>Bold</strong> &amp; <em>i</em> &lt;not a tag&gt;</p></div>",
      ),
    ).toBe("unescaped");
  });

  it("fails when Resend escaped the variable", () => {
    expect(classifyDeliveredHtml("<div>&lt;p&gt;&lt;strong&gt;Bold&lt;/strong&gt;</div>")).toBe(
      "escaped",
    );
  });

  it("fails when the variable is absent", () => {
    expect(classifyDeliveredHtml("<div></div>")).toBe("missing");
  });
});
