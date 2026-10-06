/**
 * The member half of the Loan workflow (ALE-358): request an item, cancel an
 * own Loan, and the labels and messages both share.
 *
 * Components keep form binding and rendering; this module owns what a
 * transition means for the rest of the app:
 *
 * - **Freshness rule.** A member Loan transition stales the catalog list, the
 *   catalog item, the my-loans list, and that Loan's detail. Request and
 *   cancel both apply all four, so a cancellation frees the item in the list
 *   as well as on its own page.
 * - **Error copy.** One code → member-message map read through `apiProblem`;
 *   otherwise Phoenix's `detail`, then a generic sentence.
 * - **Dates.** Loan dates are Club Calendar (`Europe/Dublin`) civil dates, so
 *   the request defaults are computed there rather than in the browser's zone.
 *
 * Whether a Loan can still be cancelled is Phoenix's `cancellable` field
 * (`LoanPolicy`); the frontend does not derive it.
 */
import {
	inventoryCatalogListItemsQueryKey,
	inventoryCatalogRequestLoanMutation,
	inventoryCatalogShowItemQueryKey,
	inventoryMemberLoansCancelMutation,
	inventoryMemberLoansListQueryKey,
	inventoryMemberLoansShowQueryKey,
	type InventoryCatalogRequestLoanData,
	type InventoryCatalogRequestLoanError,
	type InventoryCatalogRequestLoanResponse,
	type InventoryMemberLoan,
	type InventoryMemberLoansCancelData,
	type InventoryMemberLoansCancelError,
	type InventoryMemberLoansCancelResponse,
	type Options,
} from "@dhc/api-client";
import {
	createMutation,
	useQueryClient,
	type MutationOptions,
	type QueryClient,
} from "@tanstack/svelte-query";
import {
	fromAbsolute,
	toCalendarDate,
	type CalendarDate,
} from "@internationalized/date";
import { toast } from "svelte-sonner";
import { apiProblem } from "#lib/api-error.js";

/** The Club Calendar's zone; every Loan date is a civil date here. */
export const CLUB_TIME_ZONE = "Europe/Dublin";

const DEFAULT_LOAN_DAYS = 7;

export type RequestLoanFn = (
	vars: Pick<InventoryCatalogRequestLoanData, "body" | "path">,
) => Promise<InventoryCatalogRequestLoanResponse>;
export type CancelLoanFn = (
	vars: Pick<InventoryMemberLoansCancelData, "body" | "path">,
) => Promise<InventoryMemberLoansCancelResponse>;

/** Where transition feedback goes; svelte-sonner's `toast` by default. */
export type LoanNotifier = {
	success: (message: string) => void;
	error: (message: string) => void;
};

type TransitionHooks = {
	/** Runs after the success toast, before the freshness rule settles. */
	onSuccess?: (loan: InventoryMemberLoan) => void;
	notify?: LoanNotifier;
};

export type RequestLoanHooks = TransitionHooks & {
	/** Substitute the API call (browser tests); defaults to the generated client. */
	requestLoan?: RequestLoanFn;
};
export type CancelLoanHooks = TransitionHooks & {
	/** Substitute the API call (tests); defaults to the generated client. */
	cancelLoan?: CancelLoanFn;
};

export type LoanDates = {
	/** Today in the Club Calendar; the earliest requestable start. */
	today: CalendarDate;
	startsOn: string;
	dueOn: string;
};

const defaultNotifier: LoanNotifier = {
	success: (message) => toast.success(message),
	error: (message) => toast.error(message),
};

/** The member sentence for a member Loan rejection code, if it has one. */
function messageForCode(code: string | undefined): string | undefined {
	switch (code) {
		case "duplicate_request":
			return "You already have a pending request for this item.";
		case "item_unavailable":
			return "This item can't be requested right now.";
		case "not_cancellable":
			return "This loan can no longer be cancelled.";
		default:
			return undefined;
	}
}

export const REQUEST_FAILED = "Couldn't send the request.";
export const CANCEL_FAILED = "Couldn't cancel the loan.";

/** The member-facing sentence for a failed request or cancel. */
export function memberLoanErrorMessage(
	cause: unknown,
	fallback: string,
): string {
	const problem = apiProblem(cause);
	return messageForCode(problem?.code) ?? problem?.detail ?? fallback;
}

/** Applies the freshness rule for one member Loan transition. */
export async function staleMemberLoanTransition(
	queryClient: QueryClient,
	{ itemSlug, loanId }: { itemSlug: string; loanId: string },
): Promise<void> {
	await Promise.all([
		queryClient.invalidateQueries({
			queryKey: inventoryCatalogListItemsQueryKey(),
		}),
		queryClient.invalidateQueries({
			queryKey: inventoryCatalogShowItemQueryKey({
				path: { slugOrId: itemSlug },
			}),
		}),
		queryClient.invalidateQueries({
			queryKey: inventoryMemberLoansListQueryKey(),
		}),
		queryClient.invalidateQueries({
			queryKey: inventoryMemberLoansShowQueryKey({ path: { loanId } }),
		}),
	]);
}

/** Mutation options for requesting `slug`; `createRequestLoan` wraps them. */
export function requestLoanOptions(
	queryClient: QueryClient,
	slug: string,
	hooks: RequestLoanHooks = {},
): MutationOptions<
	InventoryCatalogRequestLoanResponse,
	InventoryCatalogRequestLoanError,
	Options<InventoryCatalogRequestLoanData>
> {
	const notify = hooks.notify ?? defaultNotifier;
	return {
		...inventoryCatalogRequestLoanMutation(),
		...(hooks.requestLoan && { mutationFn: hooks.requestLoan }),
		onSuccess: async (response) => {
			notify.success("Request sent — you'll hear back once reviewed.");
			hooks.onSuccess?.(response.data);
			// The page's slug, not the snapshot: it is the key the item page used.
			await staleMemberLoanTransition(queryClient, {
				itemSlug: slug,
				loanId: response.data.id,
			});
		},
		onError: (error) => {
			notify.error(memberLoanErrorMessage(error, REQUEST_FAILED));
		},
	};
}

/** Mutation options for cancelling `loanId`; `createCancelLoan` wraps them. */
export function cancelLoanOptions(
	queryClient: QueryClient,
	loanId: string,
	hooks: CancelLoanHooks = {},
): MutationOptions<
	InventoryMemberLoansCancelResponse,
	InventoryMemberLoansCancelError,
	Options<InventoryMemberLoansCancelData>
> {
	const notify = hooks.notify ?? defaultNotifier;
	return {
		...inventoryMemberLoansCancelMutation(),
		...(hooks.cancelLoan && { mutationFn: hooks.cancelLoan }),
		onSuccess: async (response) => {
			notify.success("Loan cancelled — the item is available again.");
			hooks.onSuccess?.(response.data);
			await staleMemberLoanTransition(queryClient, {
				itemSlug: response.data.itemSlug,
				loanId,
			});
		},
		onError: (error) => {
			notify.error(memberLoanErrorMessage(error, CANCEL_FAILED));
		},
	};
}

/**
 * Request the item `slug()` for the calling member. Call during component
 * setup; `mutate({ path: { slugOrId }, body: { startsOn, dueOn, note? } })`.
 */
export function createRequestLoan(
	slug: () => string,
	hooks: () => RequestLoanHooks = () => ({}),
) {
	const queryClient = useQueryClient();
	return createMutation(() => requestLoanOptions(queryClient, slug(), hooks()));
}

/**
 * Cancel the calling member's Loan `loanId()`. Call during component setup;
 * `mutate({ path: { loanId }, body: { note? } })`.
 */
export function createCancelLoan(
	loanId: () => string,
	hooks: () => CancelLoanHooks = () => ({}),
) {
	const queryClient = useQueryClient();
	return createMutation(() =>
		cancelLoanOptions(queryClient, loanId(), hooks()),
	);
}

/** Today and the default one-week window, in Club Calendar days. */
export function defaultLoanDates(now: number = Date.now()): LoanDates {
	const today = toCalendarDate(fromAbsolute(now, CLUB_TIME_ZONE));
	return {
		today,
		startsOn: today.toString(),
		dueOn: today.add({ days: DEFAULT_LOAN_DAYS }).toString(),
	};
}

export function availabilityLabel(reason: string): string {
	switch (reason) {
		case "available":
			return "Available";
		case "on_loan":
			return "On loan";
		case "maintenance":
			return "Maintenance";
		default:
			return reason;
	}
}

export function loanStatusLabel(status: InventoryMemberLoan["status"]): string {
	switch (status) {
		case "requested":
			return "Requested";
		case "approved":
			return "Approved";
		case "rejected":
			return "Rejected";
		case "cancelled":
			return "Cancelled";
		case "checked_out":
			return "Checked out";
		case "returned":
			return "Returned";
	}
}
