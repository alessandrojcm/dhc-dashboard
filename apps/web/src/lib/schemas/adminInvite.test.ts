import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as v from "valibot";
import {
	adminInviteSchema,
	bulkInviteSchema,
	type AdminInviteInput,
} from "#lib/schemas/adminInvite.js";

const entry = {
	firstName: "Aoife",
	lastName: "Byrne",
	email: "Aoife.Byrne@Example.COM",
	phoneNumber: "+353871234567",
	dateOfBirth: "1990-05-17",
	pricingTier: "coach",
} satisfies AdminInviteInput;

function issuePaths<TSchema extends v.GenericSchema>(
	schema: TSchema,
	input: v.InferInput<TSchema>,
) {
	const result = v.safeParse(schema, input);
	expect(result.success).toBe(false);
	return (result.issues ?? []).map((issue) => ({
		path: v.getDotPath(issue),
		message: issue.message,
	}));
}

describe("admin invite schema", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-10-06T12:00:00"));
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("turns an entry into the exact invitationsCreate invite", () => {
		expect(v.parse(adminInviteSchema, entry)).toStrictEqual({
			firstName: "Aoife",
			lastName: "Byrne",
			email: "aoife.byrne@example.com",
			phoneNumber: "+353 87 123 4567",
			dateOfBirth: "1990-05-17",
			pricingTier: "coach",
		});
	});

	it("defaults the pricing tier to standard", () => {
		const { pricingTier: _, ...withoutTier } = entry;
		expect(v.parse(adminInviteSchema, withoutTier).pricingTier).toBe(
			"standard",
		);
	});

	it("lowercases the email", () => {
		expect(
			v.parse(adminInviteSchema, { ...entry, email: "NIAMH@DHC.IE" }).email,
		).toBe("niamh@dhc.ie");
	});

	it("rejects anyone under 16 at the date of birth", () => {
		expect(
			issuePaths(adminInviteSchema, { ...entry, dateOfBirth: "2011-01-01" }),
		).toStrictEqual([
			{ path: "dateOfBirth", message: "You must be at least 16 years old." },
		]);
	});

	it("reports every missing field, required message first", () => {
		const issues = issuePaths(adminInviteSchema, {
			firstName: "",
			lastName: "",
			email: "",
			phoneNumber: "",
			dateOfBirth: "",
		});
		const firstPerField = issues.filter(
			(issue, index) =>
				issues.findIndex((other) => other.path === issue.path) === index,
		);
		expect(firstPerField).toStrictEqual([
			{ path: "firstName", message: "First name is required." },
			{ path: "lastName", message: "Last name is required." },
			{ path: "email", message: "Please enter an email." },
			{ path: "phoneNumber", message: "Phone number is required." },
			{ path: "dateOfBirth", message: "Date of birth is required." },
		]);
	});
});

describe("bulk invite schema", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-10-06T12:00:00"));
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("turns the list into the exact invitationsCreate body", () => {
		expect(
			v.parse(bulkInviteSchema, {
				invites: [entry, { ...entry, email: "Niamh@dhc.ie" }],
			}),
		).toStrictEqual({
			invites: [
				{
					firstName: "Aoife",
					lastName: "Byrne",
					email: "aoife.byrne@example.com",
					phoneNumber: "+353 87 123 4567",
					dateOfBirth: "1990-05-17",
					pricingTier: "coach",
				},
				{
					firstName: "Aoife",
					lastName: "Byrne",
					email: "niamh@dhc.ie",
					phoneNumber: "+353 87 123 4567",
					dateOfBirth: "1990-05-17",
					pricingTier: "coach",
				},
			],
		});
	});

	it("accepts entries the drawer already validated", () => {
		const validated = v.parse(adminInviteSchema, entry);
		expect(v.parse(bulkInviteSchema, { invites: [validated] })).toStrictEqual({
			invites: [validated],
		});
	});

	it("rejects an empty list", () => {
		expect(issuePaths(bulkInviteSchema, { invites: [] })).toStrictEqual([
			{ path: "invites", message: "Add at least one invite." },
		]);
	});

	it("rejects an under-16 entry in the list", () => {
		expect(
			issuePaths(bulkInviteSchema, {
				invites: [entry, { ...entry, dateOfBirth: "2011-01-01" }],
			}),
		).toStrictEqual([
			{
				path: "invites.1.dateOfBirth",
				message: "You must be at least 16 years old.",
			},
		]);
	});
});
