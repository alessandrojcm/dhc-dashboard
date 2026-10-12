import type { BeginnersIntakePage } from "@dhc/api-client";
import { describe, expect, it } from "vitest";
import {
	INACTIVE_PAGE,
	intakeActionLabel,
	intakeCopy,
	intakeDetails,
	startsCheckout,
} from "#lib/beginners-workshops/intake-page.js";

const pay: BeginnersIntakePage = {
	state: "pay",
	action: "pay",
	closedReason: null,
	firstName: "Aoife",
	workshop: {
		date: "2026-11-14",
		startTime: "18:30",
		venue: "St. Andrew's Hall",
	},
	feeCents: 4000,
};

describe("the Intake page presentation (ALE-381)", () => {
	it("words Phoenix's one action; only pay and continue_payment start checkout", () => {
		expect(intakeActionLabel(pay)).toBe("Pay for your place");
		expect(startsCheckout(pay)).toBe(true);
		expect(startsCheckout({ ...pay, action: "continue_payment" })).toBe(true);
		expect(startsCheckout({ ...pay, action: "check_again" })).toBe(false);
		expect(intakeActionLabel({ ...pay, action: "none" })).toBeNull();
	});

	it("distinguishes a payment closed by the cutoff from an inactive link", () => {
		expect(
			intakeCopy({
				...pay,
				state: "closed",
				action: "none",
				closedReason: "payment_closed",
			}).title,
		).toBe("Payment has closed");
		expect(intakeCopy(INACTIVE_PAGE).title).toBe(
			"This link is no longer active",
		);
	});

	it("shows the workshop facts, and nothing on an inactive link", () => {
		expect(intakeDetails(pay)).toEqual({
			greeting: "Hi Aoife,",
			date: "Sat 14 Nov 2026",
			time: "18:30",
			venue: "St. Andrew's Hall",
			fee: "€40.00",
		});
		expect(intakeDetails(INACTIVE_PAGE)).toBeNull();
	});
});
