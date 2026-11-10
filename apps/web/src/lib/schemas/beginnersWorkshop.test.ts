import { describe, expect, it } from "vitest";
import * as v from "valibot";
import {
	deletePersonSchema,
	fastTrackNewPersonSchema,
	fastTrackWaitlistPersonSchema,
	rescheduleWorkshopSchema,
	scheduleWorkshopsSchema,
	workshopSettingsSchema,
	recordPersonManualRefundSchema,
	refundPersonCreditSchema,
	withdrawPersonSchema,
	workshopStaffSchema,
} from "#lib/schemas/beginnersWorkshop.js";

const shared = {
	venue: "  St. Andrew's Hall ",
	startTime: "18:30",
	endTime: "20:30",
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
					destinationName: null,
					destinationAddress: null,
					directionsUrl: null,
					destinationPlaceId: null,
					destinationAttributions: [],
					startTime: "18:30",
					endTime: "20:30",
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
					destinationName: null,
					destinationAddress: null,
					directionsUrl: null,
					destinationPlaceId: null,
					destinationAttributions: [],
					startTime: "18:30",
					endTime: "20:30",
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
			endTime: "",
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
				"endTime",
				"capacity",
				"fee",
				"paymentWindowDays",
				"workshops.0.date",
			]),
		);
	});

	it("requires the end time to be after the start time", () => {
		const result = v.safeParse(scheduleWorkshopsSchema, {
			...shared,
			endTime: "18:30",
			workshops: [{ date: "2026-11-14" }],
		});

		expect(result.success).toBe(false);
		expect(result.issues?.map((issue) => v.getDotPath(issue))).toContain(
			"endTime",
		);
		expect(result.issues?.map((issue) => issue.message)).toContain(
			"End time must be after start time.",
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

describe("ALE-421: the Waitlist tab's money commands", () => {
	const waitlistId = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";
	const refundId = "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab001";

	it("sends the refund-or-forfeit choice as Phoenix's flag, and nothing unchosen", () => {
		expect(
			v.parse(withdrawPersonSchema, {
				waitlistId,
				refund: "refund",
				note: " Moved away ",
			}),
		).toEqual({ waitlistId, body: { refund: true, note: "Moved away" } });
		expect(v.parse(withdrawPersonSchema, { waitlistId })).toEqual({
			waitlistId,
			body: {},
		});
		expect(
			v.parse(deletePersonSchema, { waitlistId, refund: "forfeit" }),
		).toEqual({ waitlistId, body: { refund: false } });
		expect(v.parse(deletePersonSchema, { waitlistId })).toEqual({
			waitlistId,
			body: {},
		});
	});

	it("checks the 500-character note like the console does", () => {
		const long = "x".repeat(501);
		for (const [schema, input] of [
			[withdrawPersonSchema, { waitlistId, note: long }],
			[refundPersonCreditSchema, { waitlistId, note: long }],
			[recordPersonManualRefundSchema, { waitlistId, refundId, note: long }],
		] as const) {
			const result = v.safeParse(schema, input);
			expect(result.success).toBe(false);
			expect(result.issues?.[0]?.message).toBe(
				"Keep the note under 500 characters.",
			);
		}
		expect(
			v.parse(recordPersonManualRefundSchema, {
				waitlistId,
				refundId,
				note: "  ",
			}),
		).toEqual({ waitlistId, refundId, body: {} });
	});
});

describe("destination details (ALE-441)", () => {
	const destination = {
		destination_name: " National Basketball Arena ",
		destination_address: "Tymon Park, Dublin 6w",
		directions_url: "https://maps.app.goo.gl/AbCdEf",
	};
	const sent = {
		destinationName: "National Basketball Arena",
		destinationAddress: "Tymon Park, Dublin 6w",
		directionsUrl: "https://maps.app.goo.gl/AbCdEf",
		destinationPlaceId: null,
		destinationAttributions: [],
	};

	it("gives every scheduled date its own copy of the shared destination", () => {
		const { workshops } = v.parse(scheduleWorkshopsSchema, {
			...shared,
			...destination,
			workshops: [{ date: "2026-11-14" }, { date: "2026-11-21" }],
		});

		for (const workshop of workshops) expect(workshop).toMatchObject(sent);
	});

	it("refuses a non-https directions link on the field", () => {
		const result = v.safeParse(scheduleWorkshopsSchema, {
			...shared,
			directions_url: "javascript:alert(1)",
			workshops: [{ date: "2026-11-14" }],
		});

		expect(result.success).toBe(false);
		expect(
			(result.issues ?? []).map((issue) => [
				v.getDotPath(issue),
				issue.message,
			]),
		).toEqual([["directions_url", "Directions link must be an https link"]]);
	});

	const reschedule = {
		id: "3f9b7c5e-0e4c-4c39-9f0a-7a0f3f1a7b10",
		date: "2026-11-14",
		startTime: "18:30",
		endTime: "20:30",
		venue: " St. Andrew's Hall ",
		paymentCutoffDate: "2026-11-11",
		paymentCutoffTime: "18:30",
		contactFromDate: "",
	};

	it("sends a reschedule's move together with its destination", () => {
		const output = v.parse(rescheduleWorkshopSchema, {
			...reschedule,
			...destination,
			operation: "reschedule",
		});

		expect(output).toEqual({
			id: reschedule.id,
			operation: "reschedule",
			body: {
				date: "2026-11-14",
				startTime: "18:30",
				endTime: "20:30",
				venue: "St. Andrew's Hall",
				paymentCutoffDate: "2026-11-11",
				paymentCutoffTime: "18:30",
				contactFromDate: undefined,
				...sent,
			},
		});
	});

	it("sends a destination-only change with just the venue it describes", () => {
		const output = v.parse(rescheduleWorkshopSchema, {
			...reschedule,
			destination_name: "",
			destination_address: "Tymon Park, Dublin 6w",
			directions_url: "",
			operation: "destination",
		});

		// Emptied controls clear the saved values.
		expect(output).toEqual({
			id: reschedule.id,
			operation: "destination",
			body: {
				venue: "St. Andrew's Hall",
				destinationName: null,
				destinationAddress: "Tymon Park, Dublin 6w",
				directionsUrl: null,
				destinationPlaceId: null,
				destinationAttributions: [],
			},
		});
	});

	it("sends a selected Google place and its credits on every date (ALE-442)", () => {
		const { workshops } = v.parse(scheduleWorkshopsSchema, {
			...shared,
			destination_name: "Synthetic Fencing Hall",
			destination_address: "1 Example Street",
			destination_place_id: "place_hall",
			destination_attributions:
				'[{"provider":"Venue Guide","providerUri":null}]',
			workshops: [{ date: "2026-11-14" }, { date: "2026-11-21" }],
		});

		for (const workshop of workshops)
			expect(workshop).toMatchObject({
				destinationPlaceId: "place_hall",
				destinationAttributions: [
					{ provider: "Venue Guide", providerUri: null },
				],
			});
	});
});
