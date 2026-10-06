import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as v from "valibot";
import beginnersWaitlistSchema from "#lib/schemas/beginnersWaitlist.js";

const adult = {
	firstName: "Aoife",
	lastName: "Byrne",
	email: "Aoife.Byrne@Example.COM",
	phoneNumber: "+353871234567",
	dateOfBirth: "1990-05-17",
	medicalConditions: "",
	pronouns: "she/her",
	gender: "woman",
	socialMediaConsent: "yes_unrecognizable",
};

const minor = {
	...adult,
	dateOfBirth: "2009-03-01",
	guardianFirstName: "Niamh",
	guardianLastName: "Byrne",
	guardianPhoneNumber: "+353861234567",
};

function issuePaths(input: Record<string, string | undefined>) {
	const result = v.safeParse(beginnersWaitlistSchema, input);
	expect(result.success).toBe(false);
	return (result.issues ?? []).map((issue) => ({
		path: v.getDotPath(issue),
		message: issue.message,
	}));
}

describe("beginners waitlist form schema", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-10-06T12:00:00"));
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("turns a valid adult submission into the exact waitlistCreateEntry body", () => {
		expect(v.parse(beginnersWaitlistSchema, adult)).toStrictEqual({
			firstName: "Aoife",
			lastName: "Byrne",
			email: "aoife.byrne@example.com",
			phoneNumber: "+353 87 123 4567",
			dateOfBirth: "1990-05-17",
			medicalConditions: "",
			pronouns: "she/her",
			gender: "woman",
			socialMediaConsent: "yes_unrecognizable",
		});
	});

	it("rejects an applicant under 16 on dateOfBirth", () => {
		expect(issuePaths({ ...adult, dateOfBirth: "2010-10-07" })).toEqual([
			{ path: "dateOfBirth", message: "You must be at least 16 years old." },
		]);
	});

	it("accepts an applicant on their 16th birthday as a minor", () => {
		expect(
			v.parse(beginnersWaitlistSchema, { ...minor, dateOfBirth: "2010-10-06" }),
		).toMatchObject({ dateOfBirth: "2010-10-06", guardianFirstName: "Niamh" });
	});

	it("rejects a date of birth that is not a YYYY-MM-DD date", () => {
		expect(
			issuePaths({ ...adult, dateOfBirth: "2026-10-06T00:00:00.000Z" }),
		).toEqual([{ path: "dateOfBirth", message: "Date of birth is required." }]);
	});

	it("reports missing guardian details for a minor at the guardian fields", () => {
		expect(
			issuePaths({
				...minor,
				guardianFirstName: "",
				guardianLastName: undefined,
				guardianPhoneNumber: "",
			}),
		).toEqual([
			{
				path: "guardianFirstName",
				message: "Guardian first name is required for under 18s.",
			},
			{
				path: "guardianLastName",
				message: "Guardian last name is required for under 18s.",
			},
			{
				path: "guardianPhoneNumber",
				message: "Guardian phone number is required for under 18s.",
			},
		]);
	});

	it("rejects an invalid guardian phone number for a minor", () => {
		expect(issuePaths({ ...minor, guardianPhoneNumber: "12" })).toEqual([
			{ path: "guardianPhoneNumber", message: "Invalid phone number" },
		]);
	});

	it("reports guardian issues alongside unrelated field issues", () => {
		expect(
			issuePaths({ ...minor, firstName: "", guardianFirstName: "" }),
		).toEqual([
			{ path: "firstName", message: "First name is required." },
			{
				path: "guardianFirstName",
				message: "Guardian first name is required for under 18s.",
			},
		]);
	});

	it("keeps a minor's guardian details with a normalised phone number", () => {
		expect(v.parse(beginnersWaitlistSchema, minor)).toStrictEqual({
			firstName: "Aoife",
			lastName: "Byrne",
			email: "aoife.byrne@example.com",
			phoneNumber: "+353 87 123 4567",
			dateOfBirth: "2009-03-01",
			medicalConditions: "",
			pronouns: "she/her",
			gender: "woman",
			socialMediaConsent: "yes_unrecognizable",
			guardianFirstName: "Niamh",
			guardianLastName: "Byrne",
			guardianPhoneNumber: "+353 86 123 4567",
		});
	});

	it("strips guardian fields from an adult's body", () => {
		const output = v.parse(beginnersWaitlistSchema, {
			...adult,
			guardianFirstName: "Niamh",
			guardianLastName: "",
			guardianPhoneNumber: "not a phone",
		});

		expect(output).not.toHaveProperty("guardianFirstName");
		expect(output).not.toHaveProperty("guardianLastName");
		expect(output).not.toHaveProperty("guardianPhoneNumber");
	});

	it("normalises a loosely typed international phone number", () => {
		expect(
			v.parse(beginnersWaitlistSchema, {
				...adult,
				phoneNumber: "+353 (87) 123-4567",
			}).phoneNumber,
		).toBe("+353 87 123 4567");
	});

	it("defaults optional pronouns and social media consent", () => {
		const { pronouns: _p, socialMediaConsent: _s, ...required } = adult;

		expect(v.parse(beginnersWaitlistSchema, required)).toMatchObject({
			pronouns: "",
			socialMediaConsent: "no",
		});
	});
});
