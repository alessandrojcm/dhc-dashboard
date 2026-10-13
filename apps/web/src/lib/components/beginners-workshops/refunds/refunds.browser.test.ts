import type { BeginnersWorkshopRefundChoice } from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import {
	personScope,
	workshopScope,
} from "#lib/beginners-workshops/refunds/scope.js";
import FailedRefundFollowUp from "./failed-refund-follow-up.svelte";
import RefundChoice from "./refund-choice.svelte";
import RefundCredit from "./refund-credit.svelte";
import WithdrawDialog from "./withdraw-dialog.svelte";

// ALE-426: what a submission does — the choice reaching Phoenix as the
// hidden `refund` field, a refusal on `refund`, Delete, and the follow-ups
// Phoenix offers in either scope — is covered end to end by
// `e2e/beginners-workshop-money.spec.ts`; these keep only what that spec
// does not reach (the timing hint, Withdraw without money, the console's
// Refund credit).

const workshopId = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";
const intakeId = "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab001";
const waitlistId = "5f0c3b2e-8a43-4a8d-9a39-5b9d8a2ab002";
const refundId = "9a0c3b2e-8a43-4a8d-9a39-5b9d8a2ab003";

const credit: BeginnersWorkshopRefundChoice = {
	source: "carried_fee",
	amountCents: 3500,
	currency: "eur",
};

const queryClient = () => new QueryClient();

/** A form's submitted values, by field name (remote-form suffixes stripped). */
function hiddenValues(form: Element): Record<string, string> {
	if (!(form instanceof HTMLFormElement)) throw new Error("not a form");
	return Object.fromEntries(
		[...form.querySelectorAll<HTMLInputElement>("input[type=hidden]")]
			.filter((input) => input.name)
			.map((input) => [input.name.split("/")[0], input.value]),
	);
}

test("Withdraw asks the choice up front in the console, with the amount and the timing hint", async () => {
	const screen = await render(WithdrawDialog, {
		scope: workshopScope(workshopId),
		intakeId,
		name: "Dara Nolan",
		choice: credit,
		refundTimingDaysToGo: 3,
		open: true,
	});

	const dialog = screen.getByRole("dialog", {
		name: "Withdraw Dara Nolan from the Waitlist",
	});
	await expect
		.element(dialog)
		.toHaveTextContent(
			"They leave the waitlist and this workshop. You can restore them to the waitlist for 3 months.",
		);
	await expect
		.element(dialog.getByText("What happens to their workshop credit?"))
		.toBeVisible();
	await expect
		.element(dialog.getByTestId("refund-amount"))
		.toHaveTextContent("Refund their workshop credit: €35.00");
	await expect
		.element(dialog.getByTestId("refund-timing-hint"))
		.toHaveTextContent("Less than 3 days to go");
	const submit = dialog.getByRole("button", { name: "Withdraw", exact: true });
	await expect.element(submit).toBeDisabled();

	await dialog
		.getByRole("radio", { name: /Refund their workshop credit/ })
		.click();
	await expect.element(submit).toBeEnabled();
	expect(
		hiddenValues(dialog.getByRole("form", { name: "Withdraw" }).element()),
	).toEqual({ id: workshopId, intakeId, refund: "refund" });
});

test("Withdraw without money asks nothing, and says so only for a workshop place", async () => {
	const person = await render(WithdrawDialog, {
		scope: personScope(waitlistId),
		name: "Bea Waiting",
		choice: null,
		open: true,
		queryClient: queryClient(),
	});
	const personDialog = person.getByRole("dialog");
	await expect.element(personDialog).toBeVisible();
	expect(personDialog.getByRole("radio").elements()).toHaveLength(0);
	expect(
		personDialog.getByText(/There is no payment to refund/).elements(),
	).toHaveLength(0);
	await expect
		.element(
			personDialog.getByRole("button", { name: "Withdraw", exact: true }),
		)
		.toBeEnabled();
	await person.unmount();

	const place = await render(WithdrawDialog, {
		scope: workshopScope(workshopId),
		intakeId,
		name: "Cian Contacted",
		choice: null,
		open: true,
	});
	await expect
		.element(place.getByText(/There is no payment to refund/))
		.toBeVisible();
});

test("without Phoenix's choice or a refusal, the choice renders nothing", async () => {
	const screen = await render(RefundChoice, {
		choice: null,
		command: "delete_person",
	});
	expect(screen.getByRole("radio").elements()).toHaveLength(0);
});

const failed = {
	id: refundId,
	amountCents: 4000,
	currency: "eur",
	reason: "carried_fee_refunded",
	carriedFee: true,
};

test("a Waitlist follow-up list without follow-ups renders no buttons", async () => {
	const screen = await render(FailedRefundFollowUp, {
		scope: personScope(waitlistId),
		refund: failed,
		availableCommands: ["link_payment"],
		queryClient: queryClient(),
	});
	await expect.element(screen.getByTestId("failed-refund")).toBeVisible();
	expect(screen.getByRole("button").elements()).toHaveLength(0);
});

test("Refund credit in the console confirms the amount first", async () => {
	const place = await render(RefundCredit, {
		scope: workshopScope(workshopId),
		intakeId,
		amount: "€35.00",
	});
	await place.getByRole("button", { name: "Refund credit" }).click();
	const dialog = place.getByRole("dialog", { name: "Refund credit" });
	await expect
		.element(dialog)
		.toHaveTextContent(
			"Refund €35.00 to the original payment? They will need to pay for their next workshop.",
		);
	expect(
		hiddenValues(dialog.getByRole("form", { name: "Refund credit" }).element()),
	).toEqual({ id: workshopId, intakeId });
});
