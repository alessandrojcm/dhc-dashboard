import { describe, expect, it } from "vitest";
import { draftHasText, previewKey } from "./draft";

describe("draftHasText", () => {
	it("is false for an empty or whitespace-only document", () => {
		expect(
			draftHasText({ type: "doc", content: [{ type: "paragraph" }] }),
		).toBe(false);
		expect(
			draftHasText({
				type: "doc",
				content: [
					{ type: "paragraph", content: [{ type: "text", text: "   " }] },
				],
			}),
		).toBe(false);
	});

	it("finds nested text", () => {
		expect(
			draftHasText({
				type: "doc",
				content: [
					{
						type: "bulletList",
						content: [
							{
								type: "listItem",
								content: [
									{
										type: "paragraph",
										content: [{ type: "text", text: "hi" }],
									},
								],
							},
						],
					},
				],
			}),
		).toBe(true);
	});
});

describe("previewKey", () => {
	it("changes with the audience", () => {
		const body = { type: "doc" as const, content: [] };
		expect(previewKey({ subject: "a", body, includeInactive: false })).not.toBe(
			previewKey({ subject: "a", body, includeInactive: true }),
		);
	});
});
