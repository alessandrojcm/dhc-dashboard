import type { BeginnersWorkshopRefundChoice } from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import {
	personScope,
	workshopScope,
} from "#lib/beginners-workshops/refunds/scope.js";
import DeleteDialog from "./delete-dialog.svelte";
import FailedRefundFollowUp from "./failed-refund-follow-up.svelte";
import RefundChoice from "./refund-choice.svelte";
import RefundCredit from "./refund-credit.svelte";
import WithdrawDialog from "./withdraw-dialog.svelte";

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

test("Withdraw asks the choice up front on the Waitlist tab from Phoenix's person read", async () => {
	const screen = await render(WithdrawDialog, {
		scope: personScope(waitlistId),
		name: "Ada Paid",
		choice: { source: "payment", amountCents: 4000, currency: "eur" },
		open: true,
		queryClient: queryClient(),
	});

	const dialog = screen.getByRole("dialog", {
		name: "Withdraw Ada Paid from the Waitlist",
	});
	await expect
		.element(dialog)
		.toHaveTextContent(
			"They leave the waitlist and any current workshop place is closed. You can restore them to the waitlist for 3 months.",
		);
	await expect
		.element(dialog.getByText("What happens to their fee?"))
		.toBeVisible();
	await expect
		.element(dialog.getByTestId("refund-amount"))
		.toHaveTextContent("Refund €40.00");
	expect(dialog.getByTestId("refund-timing-hint").elements()).toHaveLength(0);

	await dialog.getByRole("radio", { name: /Keep the payment/ }).click();
	expect(
		hiddenValues(dialog.getByRole("form", { name: "Withdraw" }).element()),
	).toEqual({ waitlistId, refund: "forfeit" });
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

test("after a refusal on `refund` the choice is asked, without an amount Phoenix did not send", async () => {
	const screen = await render(RefundChoice, {
		choice: null,
		command: "withdraw",
		refused: true,
		issues: [{ message: "Choose whether to refund or forfeit their fee" }],
	});

	await expect
		.element(screen.getByText("What happens to their fee?"))
		.toBeVisible();
	await expect
		.element(screen.getByTestId("refund-amount"))
		.toHaveTextContent("Refund in full");
	await expect
		.element(screen.getByText("Choose whether to refund or forfeit their fee"))
		.toBeVisible();
	expect(screen.getByRole("radio").elements()).toHaveLength(2);
});

test("without Phoenix's choice or a refusal, the choice renders nothing", async () => {
	const screen = await render(RefundChoice, {
		choice: null,
		command: "delete_person",
	});
	expect(screen.getByRole("radio").elements()).toHaveLength(0);
});

test("Delete asks to refund or forfeit workshop credit up front, and emails nobody", async () => {
	const screen = await render(DeleteDialog, {
		waitlistId,
		name: "Bea Removed",
		choice: credit,
		open: true,
		queryClient: queryClient(),
	});

	const dialog = screen.getByRole("dialog", { name: "Delete Bea Removed" });
	await expect.element(dialog).toHaveTextContent("Nobody is emailed.");
	await expect
		.element(dialog.getByTestId("refund-amount"))
		.toHaveTextContent("Refund their workshop credit: €35.00");
	await expect
		.element(dialog)
		.toHaveTextContent("Against their original payment.");
	const submit = dialog.getByRole("button", { name: "Delete", exact: true });
	await expect.element(submit).toBeDisabled();

	await dialog.getByRole("radio", { name: /Keep the payment/ }).click();
	await expect.element(submit).toBeEnabled();
	expect(
		hiddenValues(dialog.getByRole("form", { name: "Delete" }).element()),
	).toEqual({ waitlistId, refund: "forfeit" });
});

const failed = {
	id: refundId,
	amountCents: 4000,
	currency: "eur",
	reason: "carried_fee_refunded",
	carriedFee: true,
};

test("the console's failed refund offers only the follow-ups Phoenix lists", async () => {
	const screen = await render(FailedRefundFollowUp, {
		scope: workshopScope(workshopId),
		refund: failed,
		availableCommands: ["retry", "manual"],
		name: "Dara",
	});

	const item = screen.getByTestId("failed-refund");
	await expect
		.element(item)
		.toHaveTextContent(
			"Refund of €40.00 to Dara failed (their workshop credit). They have since paid or received another workshop credit, so this payment is still owed back.",
		);
	await expect
		.element(item.getByRole("button", { name: "Retry", exact: true }))
		.toBeVisible();
	await expect
		.element(item.getByRole("button", { name: "Record manual refund" }))
		.toBeVisible();
	expect(
		item
			.getByRole("button", { name: "Remove credit, keep payment" })
			.elements(),
	).toHaveLength(0);
	const retry = item
		.getByRole("button", { name: "Retry", exact: true })
		.element()
		.closest("form");
	expect(retry && hiddenValues(retry)).toEqual({
		id: workshopId,
		refundId,
	});

	await item.getByRole("button", { name: "Record manual refund" }).click();
	const dialog = screen.getByRole("dialog", { name: "Record manual refund" });
	await expect
		.element(dialog)
		.toHaveTextContent(
			"Record that you paid Dara €40.00 back outside Stripe. No email is sent.",
		);
});

test("the Waitlist tab's failed refund offers Forfeit while Phoenix does, by person", async () => {
	const screen = await render(FailedRefundFollowUp, {
		scope: personScope(waitlistId),
		refund: { ...failed, lastError: "card closed" },
		availableCommands: ["retry", "manual", "forfeit"],
		queryClient: queryClient(),
	});

	const item = screen.getByTestId("failed-refund");
	await expect
		.element(item)
		.toHaveTextContent(
			"Refund of €40.00 failed (card closed). Their workshop credit is available again.",
		);
	const forfeit = item.getByRole("button", {
		name: "Remove credit, keep payment",
	});
	await expect.element(forfeit).toBeVisible();
	const form = forfeit.element().closest("form");
	expect(form && hiddenValues(form)).toEqual({ waitlistId, refundId });

	await item.getByRole("button", { name: "Record manual refund" }).click();
	await expect
		.element(screen.getByRole("dialog", { name: "Record manual refund" }))
		.toHaveTextContent("Record that you paid them €40.00 back outside Stripe.");
});

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

test("Refund credit confirms the amount first, in either scope", async () => {
	const place = await render(RefundCredit, {
		scope: workshopScope(workshopId),
		intakeId,
		amount: "€35.00",
	});
	await place.getByRole("button", { name: "Refund credit" }).click();
	let dialog = place.getByRole("dialog", { name: "Refund credit" });
	await expect
		.element(dialog)
		.toHaveTextContent(
			"Refund €35.00 to the original payment? They will need to pay for their next workshop.",
		);
	expect(
		hiddenValues(dialog.getByRole("form", { name: "Refund credit" }).element()),
	).toEqual({ id: workshopId, intakeId });
	await place.unmount();

	const person = await render(RefundCredit, {
		scope: personScope(waitlistId),
		queryClient: queryClient(),
	});
	await person.getByRole("button", { name: "Refund credit" }).click();
	dialog = person.getByRole("dialog", { name: "Refund credit" });
	await expect
		.element(dialog)
		.toHaveTextContent("Refund their workshop credit to the original payment?");
	expect(
		hiddenValues(dialog.getByRole("form", { name: "Refund credit" }).element()),
	).toEqual({ waitlistId });
});
