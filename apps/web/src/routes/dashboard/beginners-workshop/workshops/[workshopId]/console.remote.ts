/**
 * ALE-380: Pause / Resume automatic Batches from the workshop console, and
 * (ALE-384) Fast-track. Thin adapters — authorize, one generated Phoenix
 * call, translate the problem. Coordinators never send a Batch: the system
 * sweep does. (ALE-382) Retry and Record manual refund follow up a failed
 * refund from Needs attention. (ALE-394) Reschedule. (ALE-386)
 * `runIntakeCommand` runs one console Intake command — Decline, Defer and
 * Confirm with Carried Fee (ALE-388), Cancel with refund (ALE-387), Resend
 * link, Rotate link — with its optional note; the console offers only
 * Phoenix's `availableCommands`. (ALE-387) `withdrawIntake` runs Withdraw
 * with its refund-or-forfeit choice. (ALE-393) `correctAttendance` corrects a
 * finalised Intake to Phoenix's `attendanceCorrections` target. (ALE-395)
 * `cancelWorkshop` cancels the workshop with an optional reason.
 */
import { form } from "$app/server";
import {
	beginnersWorkshopBatchesPause,
	beginnersWorkshopBatchesResume,
	beginnersWorkshopFastTrackNewPerson,
	beginnersWorkshopFastTrackWaitlistPerson,
	beginnersWorkshopIntakesConfirm,
	beginnersWorkshopIntakesCorrectAttendance,
	beginnersWorkshopIntakesCancelWithRefund,
	beginnersWorkshopIntakesDecline,
	beginnersWorkshopIntakesDefer,
	beginnersWorkshopIntakesResendLink,
	beginnersWorkshopIntakesRotateLink,
	beginnersWorkshopIntakesWithdraw,
	beginnersWorkshopRefundsRecordManual,
	beginnersWorkshopRefundsRetry,
	beginnersWorkshopsCancel,
	beginnersWorkshopsReschedule,
} from "@dhc/api-client";
import {
	batchesCommandSchema,
	cancelWorkshopSchema,
	correctAttendanceSchema,
	fastTrackNewPersonSchema,
	fastTrackWaitlistPersonSchema,
	intakeCommandSchema,
	recordManualRefundSchema,
	retryRefundSchema,
	rescheduleWorkshopSchema,
	withdrawIntakeSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
import {
	newPersonFormPath,
	rescheduleFormPath,
} from "#lib/server/beginners-workshops/form-paths.js";
import {
	beginnersWaitlistManageOptions,
	beginnersWorkshopsManageOptions,
} from "#lib/server/beginners-workshops/options.js";

const noFormFields = () => undefined;

export const pauseBatches = form(batchesCommandSchema, async ({ id }) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopBatchesPause({ ...options, path: { id } }),
		{ fallback: "Could not pause Batches", formPath: noFormFields },
	);
});

export const resumeBatches = form(batchesCommandSchema, async ({ id }) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopBatchesResume({ ...options, path: { id } }),
		{ fallback: "Could not resume Batches", formPath: noFormFields },
	);
});

export const fastTrackWaitlistPerson = form(
	fastTrackWaitlistPersonSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopFastTrackWaitlistPerson({
				...options,
				path: { id },
				body,
			}),
			{ fallback: "Could not fast-track this person", formPath: noFormFields },
		);
	},
);

export const fastTrackNewPerson = form(
	fastTrackNewPersonSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopFastTrackNewPerson({ ...options, path: { id }, body }),
			{
				fallback: "Could not add and fast-track this person",
				formPath: newPersonFormPath,
			},
		);
	},
);

export const retryRefund = form(retryRefundSchema, async ({ id, refundId }) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopRefundsRetry({ ...options, path: { id, refundId } }),
		{ fallback: "Could not retry the refund", formPath: noFormFields },
	);
});

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
			{
				fallback: "Could not record the manual refund",
				formPath: (field) => (field === "note" ? ["note"] : undefined),
			},
		);
	},
);

/** ALE-394: move the workshop's date, start time or venue. */
export const rescheduleWorkshop = form(
	rescheduleWorkshopSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopsReschedule({ ...options, path: { id }, body }),
			{
				fallback: "Could not reschedule the workshop",
				formPath: rescheduleFormPath,
			},
		);
	},
);

/** ALE-395: cancel the workshop (it stays visible, read-only). */
export const cancelWorkshop = form(
	cancelWorkshopSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopsCancel({ ...options, path: { id }, body }),
			{
				fallback: "Could not cancel the workshop",
				formPath: (field) => (field === "reason" ? ["reason"] : undefined),
			},
		);
	},
);

export const runIntakeCommand = form(
	intakeCommandSchema,
	async ({ id, intakeId, command, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		const request = { ...options, path: { id, intakeId }, body };
		const calls = {
			decline: beginnersWorkshopIntakesDecline,
			defer: beginnersWorkshopIntakesDefer,
			confirm: beginnersWorkshopIntakesConfirm,
			cancel_with_refund: beginnersWorkshopIntakesCancelWithRefund,
			resend_link: beginnersWorkshopIntakesResendLink,
			rotate_link: beginnersWorkshopIntakesRotateLink,
		} satisfies Record<typeof command, typeof beginnersWorkshopIntakesDecline>;
		const call = calls[command](request);
		const result = await beginnersWorkshopCommand(call, {
			fallback: "Could not run this command",
			formPath: (field) => (field === "note" ? ["note"] : undefined),
		});
		// Which button was pressed, so the console can word the outcome.
		return result.ok ? { ...result, command } : result;
	},
);

/** ALE-387: withdraw the Intake's person from the Waitlist. */
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
			{
				fallback: "Could not withdraw this person",
				formPath: (field) =>
					field === "note" || field === "refund" ? [field] : undefined,
			},
		);
	},
);

/** ALE-393: correct one Intake's attendance after finalisation. */
export const correctAttendance = form(
	correctAttendanceSchema,
	async ({ id, intakeId, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		const result = await beginnersWorkshopCommand(
			beginnersWorkshopIntakesCorrectAttendance({
				...options,
				path: { id, intakeId },
				body,
			}),
			{
				fallback: "Could not correct attendance",
				formPath: (field) => (field === "note" ? ["note"] : undefined),
			},
		);
		// Which correction was pressed, so the console can word the outcome.
		return result.ok ? { ...result, to: body.to } : result;
	},
);
