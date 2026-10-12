import { describe, expect, it } from "vitest";
import * as v from "valibot";
import {
	fastTrackNewPersonSchema,
	fastTrackWaitlistPersonSchema,
	scheduleWorkshopsSchema,
	workshopSettingsSchema,
	workshopStaffSchema,
} from "#lib/schemas/beginnersWorkshop.js";

const shared = {
	venue: "  St. Andrew's Hall ",
	startTime: "18:30",
	capacity: 16,
	fee: 40,
	paymentWindowDays: 7,
};

describe("scheduleWorkshopsSchema", () => {
	it("sends one request entry per date with the shared values, fee in cents", () => {
		const output = v.parse(scheduleWorkshopsSchema, {
			...shared,
			fee: 39.99,
			workshops: [
				{ date: "2026-11-14", paymentCutoffDate: "", contactFromDate: "" },
				{
					date: "2026-12-05",
					paymentCutoffDate: "2026-12-01",
					contactFromDate: "2026-11-20",
				},
			],
		});

		expect(output).toEqual({
			workshops: [
				{
					date: "2026-11-14",
					paymentCutoffDate: undefined,
					contactFromDate: undefined,
					venue: "St. Andrew's Hall",
					startTime: "18:30",
					capacity: 16,
					feeCents: 3999,
					paymentWindowDays: 7,
					coachPrincipalId: null,
					assistantPrincipalIds: [],
				},
				{
					date: "2026-12-05",
					paymentCutoffDate: "2026-12-01",
					contactFromDate: "2026-11-20",
					venue: "St. Andrew's Hall",
					startTime: "18:30",
					capacity: 16,
					feeCents: 3999,
					paymentWindowDays: 7,
					coachPrincipalId: null,
					assistantPrincipalIds: [],
				},
			],
		});
		// Blank overrides leave Phoenix's defaults: the keys vanish on the wire.
		expect(JSON.parse(JSON.stringify(output)).workshops[0]).not.toHaveProperty(
			"paymentCutoffDate",
		);
	});

	it("reports each field that cannot stand on its own", () => {
		const result = v.safeParse(scheduleWorkshopsSchema, {
			venue: "x".repeat(81),
			startTime: "",
			capacity: 0,
			fee: 0,
			paymentWindowDays: 0,
			workshops: [{ date: "" }],
		});

		expect(result.success).toBe(false);
		const paths = (result.issues ?? []).map((issue) => v.getDotPath(issue));
		expect(paths).toEqual(
			expect.arrayContaining([
				"venue",
				"startTime",
				"capacity",
				"fee",
				"paymentWindowDays",
				"workshops.0.date",
			]),
		);
	});

	it("needs at least one date and at most 20", () => {
		expect(
			v.safeParse(scheduleWorkshopsSchema, { ...shared, workshops: [] })
				.success,
		).toBe(false);
		expect(
			v.safeParse(scheduleWorkshopsSchema, {
				...shared,
				workshops: Array.from({ length: 21 }, () => ({ date: "2026-11-14" })),
			}).success,
		).toBe(false);
	});
});

describe("workshopSettingsSchema", () => {
	it("sends the path id and the settings body", () => {
		const id = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";
		expect(
			v.parse(workshopSettingsSchema, {
				id,
				capacity: 24,
				fee: 45,
				paymentWindowDays: 5,
				paymentCutoffDate: "2026-11-11",
				paymentCutoffTime: "18:30",
			}),
		).toEqual({
			id,
			body: {
				capacity: 24,
				feeCents: 4500,
				paymentWindowDays: 5,
				paymentCutoffDate: "2026-11-11",
				paymentCutoffTime: "18:30",
				contactFromDate: undefined,
			},
		});
	});
});

const WORKSHOP = "11111111-1111-4111-8111-111111111111";
const COACH = "22222222-2222-4222-8222-222222222222";
const ASSISTANT = "33333333-3333-4333-8333-333333333333";

describe("workshopStaffSchema", () => {
	it("sends the whole Staff list", () => {
		expect(
			v.parse(workshopStaffSchema, {
				id: WORKSHOP,
				coachPrincipalId: COACH,
				assistantPrincipalIds: [ASSISTANT],
			}),
		).toEqual({
			id: WORKSHOP,
			body: { coachPrincipalId: COACH, assistantPrincipalIds: [ASSISTANT] },
		});
	});

	it("sends no coach and no assistants as null and an empty list", () => {
		for (const input of [
			{ id: WORKSHOP },
			{ id: WORKSHOP, coachPrincipalId: "" },
		]) {
			expect(v.parse(workshopStaffSchema, input)).toEqual({
				id: WORKSHOP,
				body: { coachPrincipalId: null, assistantPrincipalIds: [] },
			});
		}
	});

	it("refuses a pick that is not a Member id", () => {
		expect(
			v.safeParse(workshopStaffSchema, {
				id: WORKSHOP,
				assistantPrincipalIds: ["nope"],
			}).success,
		).toBe(false);
	});
});

describe("scheduleWorkshopsSchema Staff", () => {
	it("gives every date the same optional Staff", () => {
		const output = v.parse(scheduleWorkshopsSchema, {
			...shared,
			coachPrincipalId: COACH,
			assistantPrincipalIds: [ASSISTANT],
			workshops: [{ date: "2026-11-14" }, { date: "2026-11-21" }],
		});
		for (const workshop of output.workshops) {
			expect(workshop).toMatchObject({
				coachPrincipalId: COACH,
				assistantPrincipalIds: [ASSISTANT],
			});
		}
	});
});

describe("fast-track schemas (ALE-384)", () => {
	const id = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";

	it("sends the picked Waitlist person", () => {
		const waitlistId = "0f3f9d0c-3b52-4a4f-9a51-6a3f1b2a2f10";
		expect(v.parse(fastTrackWaitlistPersonSchema, { id, waitlistId })).toEqual({
			id,
			body: { waitlistId },
		});
		expect(
			v.safeParse(fastTrackWaitlistPersonSchema, { id, waitlistId: "" })
				.success,
		).toBe(false);
	});

	it("sends a new person as the registration body, without the workshop id", () => {
		const output = v.parse(fastTrackNewPersonSchema, {
			id,
			firstName: "Ciara",
			lastName: "Referral",
			email: "Ciara@Example.com",
			phoneNumber: "+353851234567",
			dateOfBirth: "1990-03-03",
			medicalConditions: "",
			pronouns: "",
			gender: "woman (cis)",
			guardianFirstName: "ignored",
		});

		expect(output.id).toBe(id);
		expect(output.body).not.toHaveProperty("id");
		expect(output.body).not.toHaveProperty("guardianFirstName");
		expect(output.body).toMatchObject({
			firstName: "Ciara",
			email: "ciara@example.com",
			socialMediaConsent: "no",
		});
	});

	it("requires a Guardian for a minor", () => {
		const result = v.safeParse(fastTrackNewPersonSchema, {
			id,
			firstName: "Young",
			lastName: "Person",
			email: "young@example.com",
			phoneNumber: "+353851234567",
			dateOfBirth: `${new Date().getFullYear() - 17}-01-01`,
			medicalConditions: "",
			pronouns: "",
			gender: "woman (cis)",
		});
		expect(result.success).toBe(false);
	});
});
