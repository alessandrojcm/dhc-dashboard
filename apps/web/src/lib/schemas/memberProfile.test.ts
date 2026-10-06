import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as v from "valibot";
import memberProfileSchema, {
	type MemberProfileInput,
} from "#lib/schemas/memberProfile.js";
import { SocialMediaConsent } from "#lib/types.js";

const submission: MemberProfileInput = {
	firstName: "Aoife",
	lastName: "Byrne",
	phoneNumber: "+353871234567",
	dateOfBirth: "1990-05-17",
	pronouns: "she/her",
	gender: "woman (cis)",
	medicalConditions: "Asthma",
	nextOfKin: "Niamh Byrne",
	nextOfKinNumber: "+353861234567",
	weapon: ["longsword", "rapier"],
	socialMediaConsent: SocialMediaConsent.yes_unrecognizable,
};

function issuePaths(input: MemberProfileInput) {
	const result = v.safeParse(memberProfileSchema, input);
	expect(result.success).toBe(false);
	return (result.issues ?? []).map((issue) => ({
		path: v.getDotPath(issue),
		message: issue.message,
	}));
}

describe("member profile form schema", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-10-06T12:00:00"));
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("turns a valid submission into the exact membersUpdate body", () => {
		expect(v.parse(memberProfileSchema, submission)).toStrictEqual({
			firstName: "Aoife",
			lastName: "Byrne",
			phoneNumber: "+353 87 123 4567",
			dateOfBirth: "1990-05-17",
			pronouns: "she/her",
			gender: "woman (cis)",
			medicalConditions: "Asthma",
			nextOfKinName: "Niamh Byrne",
			nextOfKinPhone: "+353 86 123 4567",
			preferredWeapon: ["longsword", "rapier"],
			socialMediaConsent: "yes_unrecognizable",
		});
	});

	it("sends the normalised phone numbers and the filtered weapon list (regression)", () => {
		const body = v.parse(memberProfileSchema, {
			...submission,
			phoneNumber: "+353 871234567",
			nextOfKinNumber: "+353861234567",
			weapon: ["", "sabre", ""],
		});
		expect(body.phoneNumber).toBe("+353 87 123 4567");
		expect(body.nextOfKinPhone).toBe("+353 86 123 4567");
		expect(body.preferredWeapon).toStrictEqual(["sabre"]);
	});

	it("does not accept or send the login email", () => {
		const withEmail = { ...submission, email: "aoife@example.com" };
		const body = v.parse(memberProfileSchema, withEmail);
		expect(body).not.toHaveProperty("email");
	});

	it("keeps the date of birth a YYYY-MM-DD string and enforces the age rule", () => {
		expect(issuePaths({ ...submission, dateOfBirth: "2010-10-07" })).toEqual([
			{ path: "dateOfBirth", message: "You must be at least 16 years old." },
		]);
	});

	it("reports missing required fields at their own form field", () => {
		expect(
			issuePaths({
				...submission,
				firstName: "",
				nextOfKin: "",
				nextOfKinNumber: "",
				weapon: [""],
			}),
		).toEqual([
			{ path: "firstName", message: "First name is required." },
			{ path: "nextOfKin", message: "Please enter your next of kin." },
			{
				path: "nextOfKinNumber",
				message: "Phone number of your next of kin is required.",
			},
			{ path: "nextOfKinNumber", message: "Invalid phone number" },
			{ path: "weapon", message: "Please select at least one weapon." },
		]);
	});

	it("treats unset optional fields as absent", () => {
		const {
			pronouns: _pronouns,
			socialMediaConsent: _consent,
			...rest
		} = submission;
		const body = v.parse(memberProfileSchema, rest);
		expect(body).not.toHaveProperty("socialMediaConsent");
		expect(body).not.toHaveProperty("insuranceFormSubmitted");
		expect(body.pronouns).toBe("");
	});
});
