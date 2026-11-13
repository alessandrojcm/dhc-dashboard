import { describe, expect, it, vi } from "vitest";
import { createActor, fromPromise, waitFor } from "xstate";
import {
	reactivationMachine,
	reactivationView,
	type ReactivationImplementations,
	type ReactivationPreview,
	type ReactivationResult,
} from "./reactivation-machine";

const MEMBER = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";
const START = "2026-11-10";

const savedMethod = {
	id: "pm_sepa_saved",
	last4: "1234",
	bankCode: "37040044",
	country: "DE",
};

function preview(
	overrides: Partial<ReactivationPreview> = {},
): ReactivationPreview {
	return {
		memberId: MEMBER,
		savedPaymentMethod: savedMethod,
		membershipCoverage: { monthly: "lapsed", annual: "lapsed" },
		...overrides,
	};
}

function result(
	paymentState: ReactivationResult["paymentState"],
): ReactivationResult {
	return {
		memberId: MEMBER,
		paymentState,
		monthlySubscriptionId: "sub_monthly",
		annualSubscriptionId: "sub_annual",
	};
}

/** A Phoenix problem body as the generated client rejects with it. */
function problem(detail: string, code?: string) {
	return { errors: { detail, ...(code && { code }) } };
}

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (cause: unknown) => void;
};

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (cause: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

type Requests = Partial<
	Pick<
		ReactivationImplementations,
		"lookUpMethod" | "reactivate" | "openBillingPortal"
	>
>;

function harness(requests: Requests = {}, memberId = MEMBER) {
	const lookUpMethod = vi.fn<ReactivationImplementations["lookUpMethod"]>(
		requests.lookUpMethod ?? (async () => preview()),
	);
	const reactivate = vi.fn<ReactivationImplementations["reactivate"]>(
		requests.reactivate ?? (async () => result("succeeded")),
	);
	const openBillingPortal = vi.fn<
		ReactivationImplementations["openBillingPortal"]
	>(
		requests.openBillingPortal ??
			(async () => ({ url: "https://billing.stripe.test/session" })),
	);
	const effects: string[] = [];
	const report = vi.fn<ReactivationImplementations["report"]>((outcome) => {
		effects.push(`report:${outcome}`);
	});
	const reconcile = vi.fn<ReactivationImplementations["reconcile"]>(
		({ memberId: reconciled }) => {
			effects.push(`reconcile:${reconciled}`);
		},
	);
	const showPortal = vi.fn<ReactivationImplementations["showPortal"]>();
	const portalFailed = vi.fn<ReactivationImplementations["portalFailed"]>();
	const close = vi.fn(() => {
		effects.push("close");
	});

	const actor = createActor(
		reactivationMachine.provide({
			actors: {
				lookUpMethod: fromPromise(({ input }) => lookUpMethod(input)),
				reactivate: fromPromise(({ input }) => reactivate(input)),
				openBillingPortal: fromPromise(({ input }) => openBillingPortal(input)),
			},
			actions: {
				report: (_, outcome) => report(outcome),
				reconcile: ({ context }) => reconcile({ memberId: context.memberId }),
				showPortal: (_, input) => showPortal(input),
				portalFailed: (_, input) => portalFailed(input),
				close,
			},
		}),
		{ input: { memberId, startDate: START } },
	);

	return {
		actor,
		lookUpMethod,
		reactivate,
		openBillingPortal,
		report,
		reconcile,
		showPortal,
		portalFailed,
		close,
		effects,
	};
}

const view = (actor: ReturnType<typeof harness>["actor"]) =>
	reactivationView(actor.getSnapshot());

async function ready(h: ReturnType<typeof harness>) {
	h.actor.start();
	await waitFor(h.actor, (s) => s.matches({ ready: "selecting" }));
}

describe("reactivationMachine", () => {
	it("looks up the saved method, takes the selection and reports success", async () => {
		const h = harness();
		h.actor.start();

		expect(view(h.actor).phase).toBe("lookingUp");
		expect(h.lookUpMethod).toHaveBeenCalledWith({ memberId: MEMBER });

		await waitFor(h.actor, (s) => s.matches({ ready: "selecting" }));
		expect(view(h.actor)).toMatchObject({
			phase: "ready",
			method: savedMethod,
			submitting: false,
			problem: null,
		});
		expect(h.actor.getSnapshot().context.selection).toEqual({
			startDate: START,
			annualFeeMode: "prorated_now",
		});

		h.actor.send({
			type: "SELECT",
			startDate: "2026-12-01",
			annualFeeMode: "deferred_next_year",
		});
		h.actor.send({ type: "CONFIRM" });
		expect(view(h.actor)).toMatchObject({ phase: "ready", submitting: true });

		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.actor.getSnapshot().value).toBe("succeeded");
		expect(h.reactivate).toHaveBeenCalledWith({
			memberId: MEMBER,
			selection: {
				startDate: "2026-12-01",
				annualFeeMode: "deferred_next_year",
			},
		});
		expect(h.effects).toEqual([
			"report:succeeded",
			`reconcile:${MEMBER}`,
			"close",
		]);
	});

	it.each([
		["terminal", "terminal"],
		["pending", "pending"],
		["needs_action", "needsAction"],
	] as const)(
		"ends a %s charge in its own outcome, reconciled",
		async (paymentState, finalState) => {
			const h = harness({ reactivate: async () => result(paymentState) });
			await ready(h);

			h.actor.send({ type: "CONFIRM" });
			await waitFor(h.actor, (s) => s.status === "done");

			expect(h.actor.getSnapshot().value).toBe(finalState);
			expect(h.report).toHaveBeenCalledExactlyOnceWith(paymentState);
			expect(h.reconcile).toHaveBeenCalledExactlyOnceWith({ memberId: MEMBER });
			expect(h.close).toHaveBeenCalledOnce();
		},
	);

	it("offers the billing portal when the member has no saved method", async () => {
		const h = harness({
			lookUpMethod: async () =>
				preview({
					savedPaymentMethod: null,
					membershipCoverage: { monthly: "active", annual: "lapsed" },
				}),
		});
		h.actor.start();
		await waitFor(h.actor, (s) => s.matches("noSavedMethod"));

		expect(view(h.actor)).toEqual({
			phase: "noSavedMethod",
			openingPortal: false,
			coverage: { monthly: "active", annual: "lapsed" },
		});
		h.actor.send({ type: "CONFIRM" });
		expect(h.reactivate).not.toHaveBeenCalled();

		h.actor.send({ type: "OPEN_PORTAL" });
		expect(view(h.actor)).toMatchObject({ openingPortal: true });
		// A second click while the session is being created is the same request.
		h.actor.send({ type: "OPEN_PORTAL" });
		await waitFor(h.actor, (s) => s.matches({ noSavedMethod: "idle" }));

		expect(h.openBillingPortal).toHaveBeenCalledExactlyOnceWith({
			memberId: MEMBER,
		});
		expect(h.showPortal).toHaveBeenCalledExactlyOnceWith({
			url: "https://billing.stripe.test/session",
		});
		expect(h.close).not.toHaveBeenCalled();
	});

	it("reports a billing portal failure and lets the operator try again", async () => {
		const h = harness({
			lookUpMethod: async () => preview({ savedPaymentMethod: null }),
			openBillingPortal: async () => {
				throw problem("Stripe is unavailable");
			},
		});
		h.actor.start();
		await waitFor(h.actor, (s) => s.matches("noSavedMethod"));

		h.actor.send({ type: "OPEN_PORTAL" });
		await waitFor(h.actor, (s) => s.matches({ noSavedMethod: "idle" }));

		expect(h.portalFailed).toHaveBeenCalledWith({
			detail: "Stripe is unavailable",
		});
		expect(h.showPortal).not.toHaveBeenCalled();
		h.actor.send({ type: "OPEN_PORTAL" });
		expect(h.openBillingPortal).toHaveBeenCalledTimes(2);
	});

	it("switches to the billing portal when Phoenix refuses for want of a saved method", async () => {
		const h = harness({
			reactivate: async () => {
				throw problem("No saved payment method", "no_saved_payment_method");
			},
		});
		await ready(h);

		h.actor.send({ type: "CONFIRM" });
		await waitFor(h.actor, (s) => s.matches("noSavedMethod"));

		expect(view(h.actor).phase).toBe("noSavedMethod");
		expect(h.report).not.toHaveBeenCalled();
		expect(h.close).not.toHaveBeenCalled();
	});

	it("tells a failed lookup apart from a missing saved method", async () => {
		const h = harness({
			lookUpMethod: async () => {
				throw problem("Stripe membership reactivation failed");
			},
		});
		h.actor.start();
		await waitFor(h.actor, (s) => s.matches("lookupFailed"));

		expect(view(h.actor).phase).toBe("lookupFailed");
		h.actor.send({ type: "OPEN_PORTAL" });
		h.actor.send({ type: "CONFIRM" });
		expect(h.openBillingPortal).not.toHaveBeenCalled();
		expect(h.reactivate).not.toHaveBeenCalled();
	});

	it("keeps the selection across a failed submission and re-sends it on retry", async () => {
		let attempt = 0;
		const h = harness({
			reactivate: async () => {
				attempt += 1;
				if (attempt === 1)
					throw problem("Stripe membership reactivation failed");
				return result("pending");
			},
		});
		await ready(h);
		const selection = {
			startDate: "2027-01-15",
			annualFeeMode: "deferred_next_year",
		} as const;
		h.actor.send({ type: "SELECT", ...selection });

		h.actor.send({ type: "CONFIRM" });
		await waitFor(h.actor, (s) => s.context.problem !== null);
		expect(view(h.actor)).toMatchObject({
			phase: "ready",
			submitting: false,
			problem: "Stripe membership reactivation failed",
		});
		expect(h.actor.getSnapshot().context.selection).toEqual(selection);
		expect(h.close).not.toHaveBeenCalled();

		h.actor.send({ type: "CONFIRM" });
		expect(view(h.actor)).toMatchObject({ submitting: true, problem: null });
		await waitFor(h.actor, (s) => s.status === "done");

		expect(h.reactivate).toHaveBeenNthCalledWith(2, {
			memberId: MEMBER,
			selection,
		});
		expect(h.actor.getSnapshot().value).toBe("pending");
	});

	it("falls back to a generic message when the refusal has no detail", async () => {
		const h = harness({
			reactivate: async () => {
				throw new TypeError("Failed to fetch");
			},
		});
		await ready(h);

		h.actor.send({ type: "CONFIRM" });
		await waitFor(h.actor, (s) => s.context.problem !== null);
		expect(h.actor.getSnapshot().context.problem).toBe(
			"Failed to reactivate membership",
		);
	});

	it("submits once however often the operator confirms", async () => {
		const answer = deferred<ReactivationResult>();
		const h = harness({ reactivate: () => answer.promise });
		await ready(h);

		h.actor.send({ type: "CONFIRM" });
		h.actor.send({ type: "CONFIRM" });
		h.actor.send({
			type: "SELECT",
			startDate: "2027-02-01",
			annualFeeMode: "deferred_next_year",
		});
		answer.resolve(result("succeeded"));
		await waitFor(h.actor, (s) => s.status === "done");

		expect(h.reactivate).toHaveBeenCalledOnce();
		expect(h.reactivate).toHaveBeenCalledWith({
			memberId: MEMBER,
			selection: { startDate: START, annualFeeMode: "prorated_now" },
		});
		expect(h.report).toHaveBeenCalledOnce();
	});

	it("never submits when both subscriptions are already active", async () => {
		const h = harness({
			lookUpMethod: async () =>
				preview({
					membershipCoverage: { monthly: "active", annual: "active" },
				}),
		});
		await ready(h);

		h.actor.send({ type: "CONFIRM" });
		expect(h.actor.getSnapshot().matches({ ready: "selecting" })).toBe(true);
		expect(h.reactivate).not.toHaveBeenCalled();
	});

	it("cannot be dismissed while the charge is being submitted", async () => {
		const answer = deferred<ReactivationResult>();
		const h = harness({ reactivate: () => answer.promise });
		await ready(h);

		h.actor.send({ type: "CONFIRM" });
		h.actor.send({ type: "CLOSE" });
		expect(h.actor.getSnapshot().matches({ ready: "submitting" })).toBe(true);
		expect(h.close).not.toHaveBeenCalled();

		answer.resolve(result("pending"));
		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.report).toHaveBeenCalledWith("pending");
	});

	it("drops a lookup that answers after the operator closed the dialog", async () => {
		const answer = deferred<ReactivationPreview>();
		const h = harness({ lookUpMethod: () => answer.promise });
		h.actor.start();
		h.actor.send({ type: "CLOSE" });

		expect(h.actor.getSnapshot().value).toBe("closed");
		expect(h.close).toHaveBeenCalledOnce();
		answer.resolve(preview());
		await answer.promise;

		expect(h.actor.getSnapshot().status).toBe("done");
		expect(h.actor.getSnapshot().value).toBe("closed");
		expect(h.actor.getSnapshot().context.method).toBeNull();
	});

	it("aborts the lookup's signal when the actor is stopped", async () => {
		const signals: AbortSignal[] = [];
		const actor = createActor(
			reactivationMachine.provide({
				actors: {
					lookUpMethod: fromPromise(({ signal }) => {
						signals.push(signal);
						return new Promise<ReactivationPreview>(() => {});
					}),
				},
			}),
			{ input: { memberId: MEMBER, startDate: START } },
		);
		actor.start();
		actor.stop();

		expect(signals).toHaveLength(1);
		expect(signals[0]?.aborted).toBe(true);
	});

	it("discards a previous member's late answers in a replacement dialog", async () => {
		const firstLookup = deferred<ReactivationPreview>();
		const first = harness({ lookUpMethod: () => firstLookup.promise });
		first.actor.start();
		// The host unmounts the first member's dialog and mounts another.
		first.actor.stop();

		const second = harness(
			{
				lookUpMethod: async () =>
					preview({ memberId: OTHER, savedPaymentMethod: null }),
			},
			OTHER,
		);
		second.actor.start();
		await waitFor(second.actor, (s) => s.matches("noSavedMethod"));

		firstLookup.resolve(preview());
		await firstLookup.promise;

		expect(first.actor.getSnapshot().context.method).toBeNull();
		expect(view(second.actor).phase).toBe("noSavedMethod");
		expect(second.lookUpMethod).toHaveBeenCalledWith({ memberId: OTHER });
	});

	it("drops a submission's outcome once its dialog was torn down", async () => {
		const answer = deferred<ReactivationResult>();
		const h = harness({ reactivate: () => answer.promise });
		await ready(h);

		h.actor.send({ type: "CONFIRM" });
		// Teardown (navigation) is not a dismissal: the actor simply stops.
		h.actor.stop();
		answer.resolve(result("succeeded"));
		await answer.promise;

		expect(h.report).not.toHaveBeenCalled();
		expect(h.reconcile).not.toHaveBeenCalled();
		expect(h.close).not.toHaveBeenCalled();
	});

	it("drops a billing portal session once its dialog closed", async () => {
		const answer = deferred<{ url: string }>();
		const h = harness({
			lookUpMethod: async () => preview({ savedPaymentMethod: null }),
			openBillingPortal: () => answer.promise,
		});
		h.actor.start();
		await waitFor(h.actor, (s) => s.matches("noSavedMethod"));

		h.actor.send({ type: "OPEN_PORTAL" });
		h.actor.send({ type: "CLOSE" });
		answer.resolve({ url: "https://billing.stripe.test/late" });
		await answer.promise;

		expect(h.close).toHaveBeenCalledOnce();
		expect(h.showPortal).not.toHaveBeenCalled();
	});
});
