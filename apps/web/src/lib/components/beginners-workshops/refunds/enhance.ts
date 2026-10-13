/**
 * ALE-421: the refund module's one `enhance` adapter. Every module form
 * submits, then hands Phoenix's answer to `settleRefundCommand` (the toast
 * in the module's wording, and the scope's stale queries); the component
 * only says what happens next — close a dialog, show a refusal, or ask the
 * refund-or-forfeit choice after an issue on `refund`.
 */
import { type QueryClient, useQueryClient } from "@tanstack/svelte-query";
import type { RemoteFormField } from "$app/server";
import { toast } from "svelte-sonner";
import {
	type RefundCommandResult,
	settleRefundCommand,
} from "#lib/beginners-workshops/refunds/outcome.js";
import type { RefundScope } from "#lib/beginners-workshops/refunds/scope.js";
import type { RefundCommand } from "#lib/beginners-workshops/refunds/wording.js";

/** A note control's attributes, `fields.note.as("text")` of either scope's form. */
export type NoteProps = ReturnType<RemoteFormField<string>["as"]>;

/** What the adapter reads of a submitted remote-form instance. */
type SubmittedForm = {
	submit(): Promise<boolean>;
	readonly result: RefundCommandResult | undefined;
};

export type RefundSubmitHandlers = {
	/** The command succeeded (after the toast and invalidation). */
	done?: () => void;
	/** Phoenix refused it without naming a control. */
	failed?: (error: string) => void;
	/** The submission came back with field issues. */
	invalid?: () => void;
};

/**
 * The query client a success in `scope` invalidates: the page's for the
 * Waitlist tab, none for the console. Call during component setup.
 */
export function scopeQueryClient(
	scope: RefundScope,
	queryClient?: QueryClient,
): QueryClient | null {
	if (scope.kind !== "person") return null;
	return queryClient ?? useQueryClient();
}

export function refundSubmit(
	scope: RefundScope,
	command: RefundCommand,
	queryClient: QueryClient | null,
	handlers: RefundSubmitHandlers = {},
) {
	return async (instance: SubmittedForm) => {
		if (!(await instance.submit())) {
			handlers.invalid?.();
			return;
		}
		const result = instance.result;
		if (!result) return;
		const settled = await settleRefundCommand(scope, command, result, {
			notify: toast,
			queryClient,
		});
		if (settled.ok) handlers.done?.();
		else handlers.failed?.(settled.error);
	};
}
