import { describe, expect, it } from "vitest";
import * as v from "valibot";
import {
	scheduleWorkshopsSchema,
	workshopSettingsSchema,
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
