/**
 * ALE-421: what the refund module does with a command's answer, in either
 * scope: a success is toasted in the module's wording and invalidates what
 * the scope made stale (`refreshStale`); a refusal is handed back for the
 * form to show beside its action. The remote form's `enhance` callback is a
 * thin adapter over this.
 */
import type { QueryClient } from "@tanstack/svelte-query";
import { refreshStale, type RefundScope } from "./scope.js";
import {
	type CommandOutcome,
	refundCommandDone,
	type RefundCommand,
} from "./wording.js";

export type RefundNotify = { success(message: string): void };

/** A remote form's result: Phoenix's data (maybe with an `outcome`), or its refusal. */
export type RefundCommandResult =
	| { ok: true; data: object }
	| { ok: false; error: string };

export type RefundSettlement = { ok: true } | { ok: false; error: string };

export async function settleRefundCommand(
	scope: RefundScope,
	command: RefundCommand,
	result: RefundCommandResult,
	deps: { notify: RefundNotify; queryClient: QueryClient | null },
): Promise<RefundSettlement> {
	if (!result.ok) return { ok: false, error: result.error };
	const outcome: CommandOutcome =
		"outcome" in result.data && result.data.outcome === "already_done"
			? "already_done"
			: "done";
	deps.notify.success(refundCommandDone(command, outcome));
	await refreshStale(scope, deps.queryClient);
	return { ok: true };
}
