import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import type { PlanPricing } from "#lib/types.js";
import PricingDisplay from "./pricing-display.svelte";

const money = (amount: number) => ({
	amount,
	currency: "EUR" as const,
	precision: 2,
});

const pricing: PlanPricing = {
	proratedPrice: money(3300),
	proratedMonthlyPrice: money(1500),
	proratedAnnualPrice: money(1800),
	monthlyFee: money(4200),
	annualFee: money(3600),
	monthlyBillingStart: "2026-11-01",
	annualBillingStart: "2027-01-07",
};

// Eight hours behind Dublin: a date read as a UTC instant and formatted in the
// reader's zone would show the day before.
onHostTimeZone("America/Los_Angeles");

test("shows the billing start dates Phoenix decided, on any host zone", async () => {
	const screen = await render(PricingDisplay, {
		currentCoupon: "",
		readPricing: async () => pricing,
	});

	await expect.element(screen.getByText("From Sun 1 Nov 2026")).toBeVisible();
	await expect.element(screen.getByText("From Thu 7 Jan 2027")).toBeVisible();
});
