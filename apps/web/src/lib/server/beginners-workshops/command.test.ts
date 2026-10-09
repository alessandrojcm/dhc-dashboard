import { isValidationError } from "@sveltejs/kit";
import { describe, expect, it } from "vitest";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
import {
	scheduleFormPath,
	settingsFormPath,
} from "#lib/server/beginners-workshops/form-paths.js";

function rejection(errors: {
	detail?: string;
	code?: string;
	fields?: Record<string, string[]>;
}) {
	return Promise.resolve({ error: { errors } });
}

async function issuesOf(promise: Promise<unknown>) {
	try {
		await promise;
	} catch (cause) {
		if (isValidationError(cause)) return cause.issues;
		throw cause;
	}
	throw new Error("Expected the command to reject with invalid()");
}

describe("beginnersWorkshopCommand", () => {
	it("passes a successful response's data through", async () => {
		const result = await beginnersWorkshopCommand(
			Promise.resolve({ data: { data: [{ id: "w-1" }] } }),
			{ fallback: "nope", formPath: scheduleFormPath },
		);
		expect(result).toEqual({ ok: true, data: [{ id: "w-1" }] });
	});

	it("puts a refused workshop's field under that date's control", async () => {
		const issues = await issuesOf(
			beginnersWorkshopCommand(
				rejection({
					detail: "The contact-from date must be on or before the cutoff date",
					code: "invalid_contact_from",
					fields: { "workshops.1.contactFromDate": ["too late"] },
				}),
				{ fallback: "nope", formPath: scheduleFormPath },
			),
		);
		expect(issues).toEqual([
			{ message: "too late", path: ["workshops", 1, "contactFromDate"] },
		]);
	});

	it("puts a shared value's refusal on the shared control, fee in euro", async () => {
		const issues = await issuesOf(
			beginnersWorkshopCommand(
				rejection({
					code: "invalid_workshop",
					fields: {
						"workshops.0.venue": ["should be at most 80 character(s)"],
						"workshops.2.feeCents": ["must be less than or equal to 99999"],
					},
				}),
				{ fallback: "nope", formPath: scheduleFormPath },
			),
		);
		expect(issues).toEqual([
			{ message: "should be at most 80 character(s)", path: ["venue"] },
			{ message: "must be less than or equal to 99999", path: ["fee"] },
		]);
	});

	it("answers with the detail when no field is named", async () => {
		await expect(
			beginnersWorkshopCommand(
				rejection({
					detail: "This workshop is cancelled",
					code: "already_cancelled",
				}),
				{ fallback: "nope", formPath: settingsFormPath },
			),
		).resolves.toEqual({ ok: false, error: "This workshop is cancelled" });

		await expect(
			beginnersWorkshopCommand(Promise.resolve({ error: "boom" }), {
				fallback: "Could not save",
				formPath: settingsFormPath,
			}),
		).resolves.toEqual({ ok: false, error: "Could not save" });
	});
});

describe("form paths", () => {
	it("maps settings fields onto the settings dialog", () => {
		expect(settingsFormPath("feeCents")).toEqual(["fee"]);
		expect(settingsFormPath("paymentCutoffDate")).toEqual([
			"paymentCutoffDate",
		]);
		expect(settingsFormPath("venue")).toBeUndefined();
	});

	it("ignores fields that are not one workshop's", () => {
		expect(scheduleFormPath("workshops")).toBeUndefined();
		expect(scheduleFormPath("venue")).toBeUndefined();
		expect(scheduleFormPath("workshops.x.date")).toBeUndefined();
		expect(scheduleFormPath("workshops.0.date")).toEqual([
			"workshops",
			0,
			"date",
		]);
	});
});
