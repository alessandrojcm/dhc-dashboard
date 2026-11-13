import type { InventoryOperatorItem } from "@dhc/api-client";
import {
	assign,
	enqueueActions,
	fromPromise,
	setup,
	type SnapshotFrom,
} from "xstate";
import { apiErrorMessage } from "#lib/api-error.js";
import type { DraftGroup } from "./item-drafts";

/**
 * The quartermaster Items page's workflow (ALE-451): the routed mode (the
 * list, the create form, managing one item), the `?slug=` deep link, and what
 * each Item command's answer does — the cache it adopts or forgets, the drafts
 * it rebases, its toast, its button's success flash, and the navigation after
 * a create or a delete.
 *
 * It does not own the command transport: every Item command is a remote form
 * (`data.remote.ts`, through `inventoryCommand`) that owns its own pending and
 * validation state; the workbench controller sends the machine a `SETTLED`
 * event with the form's `{ ok, data | error }` once Phoenix answered. Nor does
 * it own server state (TanStack Query does; the injected actions adopt into
 * and invalidate the query cache) or the drafts (independent runes state in
 * the controller; the injected `rebase` action applies `rebasedDrafts`).
 *
 * Every route change bumps `generation`. A command's `SETTLED` carries the
 * generation it was submitted under, so an answer that lands after the
 * operator moved to another item (or the list) only updates the cache for the
 * item it answered for; it never rebases, flashes or navigates the new route.
 * Leaving a mode cancels its timers (the success flash, the delayed open of a
 * created item) and its deep-link lookup. One actor per page, created and
 * stopped by the controller; never a module-scope actor.
 */

export const ITEMS_PATH = "/dashboard/inventory/items";

/** How long a submit button shows its success state. */
export const SUCCESS_FLASH_MS = 650;

/** The forms whose submit button flashes on success. */
export type FlashedForm =
	| "create"
	| "details"
	| "placement"
	| "category"
	| "maintenance";

/** What an Item command's remote form answers (`inventoryCommand`). */
export type ItemCommandResult =
	| { ok: true; data: InventoryOperatorItem }
	| { ok: false; error: string };

type CommandOutcome =
	/** Flashes Add, then opens the new item. No toast. */
	| { kind: "create" }
	/** A management form: a refusal stays inline; a success flashes its button. */
	| { kind: "edit"; form: Exclude<FlashedForm, "create"> & DraftGroup }
	/** Archive and restore answer with a toast either way. */
	| { kind: "lifecycle"; success: string }
	/** Returns to the list: the navigation is the feedback. */
	| { kind: "delete" };

/** Each Item command's outcome, declared once. */
export const ITEM_COMMANDS = {
	create: { kind: "create" },
	update: { kind: "edit", form: "details" },
	move: { kind: "edit", form: "placement" },
	changeCategory: { kind: "edit", form: "category" },
	startMaintenance: { kind: "edit", form: "maintenance" },
	endMaintenance: { kind: "edit", form: "maintenance" },
	archive: { kind: "lifecycle", success: "Item archived" },
	restore: { kind: "lifecycle", success: "Item restored" },
	delete: { kind: "delete" },
} as const satisfies Record<string, CommandOutcome>;

export type ItemCommand = keyof typeof ITEM_COMMANDS;
type OutcomeKind = CommandOutcome["kind"];

/** Where the URL says the page is. */
export type WorkbenchRoute = {
	/** The `[[itemId]]` param: an item's code (or id), `new`, or none. */
	routeId: string | undefined;
	/** The trimmed `?slug=` deep link, if any. */
	slug: string | undefined;
	/** The list's own query string (without `slug`), `""` or `?…`. */
	search: string;
};

/** The Items page's URL for `route` (an item code, `new`), keeping `search`. */
export function itemsHref(search: string, route?: string): string {
	return route ? `${ITEMS_PATH}/${route}${search}` : `${ITEMS_PATH}${search}`;
}

export type ItemWorkbenchInput = WorkbenchRoute & { successFlashMs?: number };

export type ItemWorkbenchContext = {
	route: WorkbenchRoute;
	/** Bumped on every route change; stale command answers are told apart by it. */
	generation: number;
	/** The last deep link looked up, so going back to it does not bounce forward. */
	lookedUpSlug: string | undefined;
	successFlashMs: number;
	flashing: FlashedForm | null;
	/** The created item's route, opened once Add has flashed. */
	createdHref: string | null;
	deleteConfirmOpen: boolean;
};

export type ItemCommandSettled = {
	type: "SETTLED";
	command: ItemCommand;
	/** The `generation` the command was submitted under. */
	generation: number;
	/** The `routeId` the command was submitted under. */
	routeId: string | undefined;
	result: ItemCommandResult;
};

export type ItemWorkbenchEvent =
	| ({ type: "ROUTED" } & WorkbenchRoute)
	| ItemCommandSettled
	| { type: "CONFIRM_DELETE"; open: boolean };

/** Implementations the controller provides through `itemWorkbenchMachine.provide`. */
export type ItemWorkbenchImplementations = {
	/** Resolves a deep link through the show read (archive-agnostic). */
	lookUpItem: (input: { slug: string }) => Promise<InventoryOperatorItem>;
	/** Writes Phoenix's answer into the show read `routeId` is served from. */
	adopt: (input: { routeId: string; item: InventoryOperatorItem }) => void;
	/** Drops the show read `routeId` is served from. */
	forget: (input: { routeId: string }) => void;
	/** Refreshes every Item list, and `slug`'s maintenance list when given. */
	invalidateLists: (input: { slug?: string }) => void;
	/** Rebases the management drafts on `item`; `own` starts again from it. */
	rebase: (input: { item: InventoryOperatorItem; own: DraftGroup }) => void;
	/** Empties the create form. */
	resetCreate: () => void;
	visit: (input: { href: string }) => void;
	notifySuccess: (input: { message: string }) => void;
	notifyError: (input: { message: string }) => void;
};

function unprovided(name: string) {
	return async (): Promise<never> => {
		throw new Error(`${name} must be provided by the host`);
	};
}

function settled(event: ItemWorkbenchEvent): ItemCommandSettled {
	if (event.type !== "SETTLED") throw new Error("expected a command answer");
	return event;
}

function answered(event: ItemWorkbenchEvent): InventoryOperatorItem {
	const { result } = settled(event);
	if (!result.ok) throw new Error("expected a successful command answer");
	return result.data;
}

function outcomeOf(event: ItemWorkbenchEvent): CommandOutcome {
	return ITEM_COMMANDS[settled(event).command];
}

function editedForm(event: ItemWorkbenchEvent) {
	const outcome = outcomeOf(event);
	if (outcome.kind !== "edit") throw new Error("expected a management form");
	return outcome.form;
}

function routeOf(event: ItemWorkbenchEvent): string {
	const { routeId } = settled(event);
	if (!routeId) throw new Error("a management command needs its item route");
	return routeId;
}

/** Routes the page to the mode its URL names. */
const toMode = [
	{ guard: "listRoute", target: "list" },
	{ guard: "createRoute", target: "creating" },
	{ target: "managing" },
] as const;

export const itemWorkbenchMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as ItemWorkbenchContext,
		events: {} as ItemWorkbenchEvent,
		input: {} as ItemWorkbenchInput,
	},
	actors: {
		lookUpItem: fromPromise<InventoryOperatorItem, { slug: string }>(
			unprovided("lookUpItem"),
		),
	},
	actions: {
		adopt: (_, _input: { routeId: string; item: InventoryOperatorItem }) => {},
		forget: (_, _input: { routeId: string }) => {},
		invalidateLists: (_, _input: { slug?: string }) => {},
		rebase: (_, _input: { item: InventoryOperatorItem; own: DraftGroup }) => {},
		resetCreate: () => {},
		visit: (_, _input: { href: string }) => {},
		notifySuccess: (_, _input: { message: string }) => {},
		notifyError: (_, _input: { message: string }) => {},
		/** A route change: a new generation, so earlier answers go stale. */
		enterRoute: assign({
			route: ({ context, event }) =>
				event.type === "ROUTED"
					? { routeId: event.routeId, slug: event.slug, search: event.search }
					: context.route,
			generation: ({ context }) => context.generation + 1,
		}),
		/** The same route, with another query string or deep link. */
		keepRoute: assign({
			route: ({ context, event }) =>
				event.type === "ROUTED"
					? { routeId: event.routeId, slug: event.slug, search: event.search }
					: context.route,
		}),
	},
	guards: {
		routeChanged: ({ context, event }) =>
			event.type === "ROUTED" && event.routeId !== context.route.routeId,
		deepLinkChanged: ({ context, event }) =>
			event.type === "ROUTED" &&
			event.routeId === undefined &&
			event.slug !== undefined &&
			event.slug !== context.lookedUpSlug,
		queryChanged: ({ context, event }) =>
			event.type === "ROUTED" &&
			(event.search !== context.route.search ||
				event.slug !== context.route.slug),
		listRoute: ({ context }) => context.route.routeId === undefined,
		createRoute: ({ context }) => context.route.routeId === "new",
		unresolvedDeepLink: ({ context }) =>
			context.route.slug !== undefined &&
			context.route.slug !== context.lookedUpSlug,
		/**
		 * An answer for the route the page still shows; with params, also of
		 * that outcome kind and result.
		 */
		fresh: (
			{ context, event },
			params?: { kind: OutcomeKind; ok: boolean },
		) => {
			if (event.type !== "SETTLED" || event.generation !== context.generation)
				return false;
			if (!params) return true;
			return (
				ITEM_COMMANDS[event.command].kind === params.kind &&
				event.result.ok === params.ok
			);
		},
	},
	delays: {
		successFlash: ({ context }) => context.successFlashMs,
	},
}).createMachine({
	id: "itemWorkbench",
	context: ({ input }) => ({
		route: { routeId: input.routeId, slug: input.slug, search: input.search },
		generation: 0,
		lookedUpSlug: undefined,
		successFlashMs: input.successFlashMs ?? SUCCESS_FLASH_MS,
		flashing: null,
		createdHref: null,
		deleteConfirmOpen: false,
	}),
	initial: "routing",
	on: {
		ROUTED: [
			{ guard: "routeChanged", target: ".routing", actions: "enterRoute" },
			{ guard: "deepLinkChanged", target: ".routing", actions: "keepRoute" },
			{ guard: "queryChanged", actions: "keepRoute" },
		],
		// An answer the page no longer shows (the operator moved on, or no
		// mode claimed it): the cache still adopts what Phoenix answered for
		// that item, and archive/restore/delete still say how it went, but no
		// draft, flash or navigation reaches the current route.
		SETTLED: {
			actions: enqueueActions(({ event, enqueue }) => {
				const outcome = ITEM_COMMANDS[event.command];
				const { result, routeId } = event;
				if (!result.ok) {
					if (outcome.kind === "lifecycle" || outcome.kind === "delete")
						enqueue({ type: "notifyError", params: { message: result.error } });
					return;
				}
				const item = result.data;
				if (outcome.kind === "delete") {
					if (routeId) enqueue({ type: "forget", params: { routeId } });
					enqueue({ type: "invalidateLists", params: {} });
					return;
				}
				if (outcome.kind === "lifecycle")
					enqueue({
						type: "notifySuccess",
						params: { message: outcome.success },
					});
				const key = outcome.kind === "create" ? item.slug : routeId;
				if (key) enqueue({ type: "adopt", params: { routeId: key, item } });
				enqueue({ type: "invalidateLists", params: { slug: item.slug } });
			}),
		},
	},
	states: {
		routing: { always: toMode },
		list: {
			initial: "checking",
			states: {
				checking: {
					always: [
						{ guard: "unresolvedDeepLink", target: "resolving" },
						{ target: "browsing" },
					],
				},
				browsing: {},
				// The loan queue's "Open item" links land here. Leaving the list
				// mid-lookup cancels the invocation, so its answer never navigates.
				resolving: {
					entry: assign({ lookedUpSlug: ({ context }) => context.route.slug }),
					invoke: {
						src: "lookUpItem",
						input: ({ context }) => ({ slug: context.lookedUpSlug ?? "" }),
						onDone: {
							target: "browsing",
							actions: {
								type: "visit",
								params: ({ event }) => ({
									href: itemsHref("", event.output.slug),
								}),
							},
						},
						onError: {
							target: "browsing",
							actions: {
								type: "notifyError",
								params: ({ event }) => ({
									message: apiErrorMessage(
										event.error,
										"No item matches that code",
									),
								}),
							},
						},
					},
				},
			},
		},
		creating: {
			initial: "editing",
			on: {
				SETTLED: [
					{
						guard: { type: "fresh", params: { kind: "create", ok: true } },
						target: ".created",
						actions: [
							assign({
								flashing: "create",
								createdHref: ({ context, event }) =>
									itemsHref(context.route.search, answered(event).slug),
							}),
							{
								type: "adopt",
								params: ({ event }) => ({
									routeId: answered(event).slug,
									item: answered(event),
								}),
							},
							{
								type: "invalidateLists",
								params: ({ event }) => ({ slug: answered(event).slug }),
							},
						],
					},
					// A refusal stays inline in the form, which keeps its draft.
					{ guard: "fresh" },
				],
			},
			states: {
				editing: {},
				// Add flashes, then the new item opens. Leaving first cancels the
				// open; either way the saved draft is emptied.
				created: {
					exit: ["resetCreate", assign({ flashing: null })],
					after: {
						successFlash: {
							target: "editing",
							actions: {
								type: "visit",
								params: ({ context }) => ({ href: context.createdHref ?? "" }),
							},
						},
					},
				},
			},
		},
		managing: {
			entry: assign({ deleteConfirmOpen: false }),
			initial: "idle",
			on: {
				CONFIRM_DELETE: {
					actions: assign({ deleteConfirmOpen: ({ event }) => event.open }),
				},
				SETTLED: [
					{
						guard: { type: "fresh", params: { kind: "edit", ok: true } },
						target: ".flashing",
						actions: [
							assign({ flashing: ({ event }) => editedForm(event) }),
							{
								type: "adopt",
								params: ({ event }) => ({
									routeId: routeOf(event),
									item: answered(event),
								}),
							},
							{
								type: "rebase",
								params: ({ event }) => ({
									item: answered(event),
									own: editedForm(event),
								}),
							},
							{
								type: "invalidateLists",
								params: ({ event }) => ({ slug: answered(event).slug }),
							},
						],
					},
					{
						guard: { type: "fresh", params: { kind: "lifecycle", ok: true } },
						actions: [
							{
								type: "notifySuccess",
								params: ({ event }) => {
									const outcome = outcomeOf(event);
									return {
										message:
											outcome.kind === "lifecycle" ? outcome.success : "",
									};
								},
							},
							{
								type: "adopt",
								params: ({ event }) => ({
									routeId: routeOf(event),
									item: answered(event),
								}),
							},
							{
								type: "rebase",
								params: ({ event }) => ({
									item: answered(event),
									own: "archive" as const,
								}),
							},
							{
								type: "invalidateLists",
								params: ({ event }) => ({ slug: answered(event).slug }),
							},
						],
					},
					{
						guard: { type: "fresh", params: { kind: "delete", ok: true } },
						target: ".deleted",
						actions: [
							assign({ deleteConfirmOpen: false }),
							{
								type: "forget",
								params: ({ event }) => ({ routeId: routeOf(event) }),
							},
							{
								type: "visit",
								params: ({ context }) => ({
									href: itemsHref(context.route.search),
								}),
							},
							{ type: "invalidateLists", params: {} },
						],
					},
					{
						guard: { type: "fresh", params: { kind: "lifecycle", ok: false } },
						actions: {
							type: "notifyError",
							params: ({ event }) => {
								const { result } = settled(event);
								return { message: result.ok ? "" : result.error };
							},
						},
					},
					{
						guard: { type: "fresh", params: { kind: "delete", ok: false } },
						actions: {
							type: "notifyError",
							params: ({ event }) => {
								const { result } = settled(event);
								return { message: result.ok ? "" : result.error };
							},
						},
					},
					// A management form's refusal stays inline in the form.
					{ guard: "fresh" },
				],
			},
			states: {
				idle: {},
				flashing: {
					exit: assign({ flashing: null }),
					after: { successFlash: "idle" },
				},
				// The item is gone and the list is opening: a late or repeated
				// answer for it must not write it back into the cache.
				deleted: {
					on: {
						SETTLED: { guard: "fresh" },
						CONFIRM_DELETE: { actions: [] },
					},
				},
			},
		},
	},
});

export type ItemWorkbenchSnapshot = SnapshotFrom<typeof itemWorkbenchMachine>;

export type ItemWorkbenchMode = "list" | "create" | "manage";

/** What the controller reads from a snapshot. */
export function itemWorkbenchView(snapshot: ItemWorkbenchSnapshot) {
	const { context } = snapshot;
	const mode: ItemWorkbenchMode = snapshot.matches("creating")
		? "create"
		: snapshot.matches("managing")
			? "manage"
			: "list";
	return {
		mode,
		/** The managed item's route param, while managing one. */
		managedId: mode === "manage" ? context.route.routeId : undefined,
		flashing: context.flashing,
		deleteConfirmOpen: mode === "manage" && context.deleteConfirmOpen,
		resolvingDeepLink: snapshot.matches({ list: "resolving" }),
	};
}
