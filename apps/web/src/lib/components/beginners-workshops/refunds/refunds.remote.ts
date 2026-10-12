/**
 * ALE-421: the refund module's remote forms, in both refund scopes — the
 * console's workshop (`id`) and the Waitlist tab's person (`waitlistId`).
 * Thin adapters: authorize, one generated Phoenix call, translate the
 * problem through `beginnersWorkshopCommand` (a refusal on `refund` or
 * `note` lands under that control). Withdraw and Delete are the Waitlist's
 * exit (`beginners.waitlist.manage`); refund credit and the failed-refund
 * follow-ups are management commands (`beginners.workshops.manage`).
 * Link Stripe payment, Cancel with refund and Decline are not here.
 */
import { form } from "$app/server";
import {
	beginnersWorkshopCarriedFeesForfeit,
	beginnersWorkshopCarriedFeesRecordManualRefund,
	beginnersWorkshopCarriedFeesRefund,
	beginnersWorkshopCarriedFeesRetryRefund,
	beginnersWorkshopIntakesDeletePerson,
	beginnersWorkshopIntakesRefundCarriedFee,
	beginnersWorkshopIntakesWithdraw,
	beginnersWorkshopIntakesWithdrawPerson,
	beginnersWorkshopRefundsForfeit,
	beginnersWorkshopRefundsRecordManual,
	beginnersWorkshopRefundsRetry,
} from "@dhc/api-client";
import { REFUND_COMMAND_FALLBACK as FALLBACK } from "#lib/beginners-workshops/refunds/wording.js";
import {
	deletePersonSchema,
	personRefundFollowUpSchema,
	recordManualRefundSchema,
	recordPersonManualRefundSchema,
	refundIntakeCreditSchema,
	refundPersonCreditSchema,
	retryRefundSchema,
	withdrawIntakeSchema,
	withdrawPersonSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
import {
	beginnersWaitlistManageOptions,
	beginnersWorkshopsManageOptions,
} from "#lib/server/beginners-workshops/options.js";

const noFormFields = () => undefined;
const noteField = (field: string) => (field === "note" ? ["note"] : undefined);
const choiceFields = (field: string) =>
	field === "note" || field === "refund" ? [field] : undefined;

/** ALE-387: withdraw a workshop place's person from the Waitlist. */
export const withdrawIntake = form(
	withdrawIntakeSchema,
	async ({ id, intakeId, body }) => {
		const options = await beginnersWaitlistManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopIntakesWithdraw({
				...options,
				path: { id, intakeId },
				body,
			}),
			{ fallback: FALLBACK.withdraw, formPath: choiceFields },
		);
	},
);

/** ALE-387: withdraw a person from the Waitlist tab. */
export const withdrawPerson = form(
	withdrawPersonSchema,
	async ({ waitlistId, body }) => {
		const options = await beginnersWaitlistManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopIntakesWithdrawPerson({
				...options,
				path: { waitlistId },
				body,
			}),
			{ fallback: FALLBACK.withdraw, formPath: choiceFields },
		);
	},
);

/** ALE-396: delete a person from the Waitlist tab. */
export const deletePerson = form(
	deletePersonSchema,
	async ({ waitlistId, body }) => {
		const options = await beginnersWaitlistManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopIntakesDeletePerson({
				...options,
				path: { waitlistId },
				body,
			}),
			{ fallback: FALLBACK.delete_person, formPath: choiceFields },
		);
	},
);

/** ALE-389: refund the workshop place's person's credit. */
export const refundIntakeCredit = form(
	refundIntakeCreditSchema,
	async ({ id, intakeId, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopIntakesRefundCarriedFee({
				...options,
				path: { id, intakeId },
				body,
			}),
			{ fallback: FALLBACK.refund_credit, formPath: noteField },
		);
	},
);

/** ALE-389: refund a person's credit from the Waitlist tab. */
export const refundPersonCredit = form(
	refundPersonCreditSchema,
	async ({ waitlistId, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopCarriedFeesRefund({
				...options,
				path: { waitlistId },
				body,
			}),
			{ fallback: FALLBACK.refund_credit, formPath: noteField },
		);
	},
);

/** ALE-382: retry a failed refund from the console's Needs attention. */
export const retryRefund = form(retryRefundSchema, async ({ id, refundId }) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopRefundsRetry({ ...options, path: { id, refundId } }),
		{ fallback: FALLBACK.retry, formPath: noFormFields },
	);
});

/** ALE-389: retry a person's failed refund from the Waitlist tab. */
export const retryPersonRefund = form(
	personRefundFollowUpSchema,
	async ({ waitlistId, refundId }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopCarriedFeesRetryRefund({
				...options,
				path: { waitlistId, refundId },
			}),
			{ fallback: FALLBACK.retry, formPath: noFormFields },
		);
	},
);

/** ALE-382: the coordinator paid the person back outside Stripe. */
export const recordManualRefund = form(
	recordManualRefundSchema,
	async ({ id, refundId, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopRefundsRecordManual({
				...options,
				path: { id, refundId },
				body,
			}),
			{ fallback: FALLBACK.manual, formPath: noteField },
		);
	},
);

/** ALE-389: Record manual refund from the Waitlist tab. */
export const recordPersonManualRefund = form(
	recordPersonManualRefundSchema,
	async ({ waitlistId, refundId, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopCarriedFeesRecordManualRefund({
				...options,
				path: { waitlistId, refundId },
				body,
			}),
			{ fallback: FALLBACK.manual, formPath: noteField },
		);
	},
);

/** ALE-389: forfeit workshop credit whose refund failed (no email). */
export const forfeitCredit = form(
	retryRefundSchema,
	async ({ id, refundId }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopRefundsForfeit({ ...options, path: { id, refundId } }),
			{ fallback: FALLBACK.forfeit, formPath: noFormFields },
		);
	},
);

/** ALE-389: forfeit a person's credit whose refund failed, from the Waitlist tab. */
export const forfeitPersonCredit = form(
	personRefundFollowUpSchema,
	async ({ waitlistId, refundId }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopCarriedFeesForfeit({
				...options,
				path: { waitlistId, refundId },
			}),
			{ fallback: FALLBACK.forfeit, formPath: noFormFields },
		);
	},
);
