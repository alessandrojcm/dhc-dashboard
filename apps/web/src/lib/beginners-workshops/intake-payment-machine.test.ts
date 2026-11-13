import type { BeginnersIntakePage } from "@dhc/api-client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createActor, fromPromise } from "xstate";
import {
	intakePaymentMachine,
	intakePaymentView,
	START_FAILED,
	type IntakePaymentStart,
} from "./intake-payment-machine";

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (error: Error) => void;
};

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

const settle = async () => {
	for (let i = 0; i < 5; i++) await Promise.resolve();
};

function page(
	overrides: Partial<BeginnersIntakePage> = {},
): BeginnersIntakePage {
	return {
		state: "pay",
		action: "pay",
		closedReason: null,
		firstName: "Aoife",
		workshop: {
			date: "2026-11-14",
			startTime: "18:30",
			endTime: null,
			venue: "St. Andrew's Hall",
		},
		feeCents: 4000,
		...overrides,
	};
}

const opened: IntakePaymentStart = {
	ok: true,
	clientSecret: "cs_test_secret",
	sessionId: "cs_test",
};

const inProgress = () =>
	page({ state: "payment_in_progress", action: "check_again" });

function harness(
	initial: BeginnersIntakePage,
	start: () => Promise<IntakePaymentStart> = async () => opened,
) {
	const startPayment = vi.fn(start);
	const refresh = vi.fn();
	const actor = createActor(
		intakePaymentMachine.provide({
			actors: { startPayment: fromPromise(() => startPayment()) },
			actions: { refresh: () => refresh() },
		}),
		{ input: { page: initial, refreshMs: 3000 } },
	).start();
	const view = () => intakePaymentView(actor.getSnapshot());
	const show = (next: BeginnersIntakePage) =>
		actor.send({ type: "PAGE", page: next });
	return { actor, startPayment, refresh, view, show };
}

afterEach(() => {
	vi.useRealTimers();
});

describe("the Intake page's payment orchestration (ALE-447)", () => {
	it("a server render never starts a payment: it waits for the mounted browser", async () => {
		const { actor, startPayment, view, show } = harness(page());
		show(page({ action: "continue_payment" }));
		await settle();
		expect(startPayment).not.toHaveBeenCalled();
		expect(view().footer).toEqual({ kind: "loading" });
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(startPayment).toHaveBeenCalledOnce();
	});

	it("starts payment automatically, once, and hands the session to the widget", async () => {
		const start = deferred<IntakePaymentStart>();
		const { actor, startPayment, view, show } = harness(
			page(),
			() => start.promise,
		);
		actor.send({ type: "MOUNTED" });
		actor.send({ type: "MOUNTED" });
		// The form's own reload lands while the POST is still in flight.
		show(page({ action: "continue_payment" }));
		actor.send({ type: "RETRY" });
		expect(view().footer).toEqual({ kind: "loading" });
		start.resolve(opened);
		await settle();
		expect(view()).toEqual({
			footer: {
				kind: "checkout",
				session: { clientSecret: "cs_test_secret", sessionId: "cs_test" },
			},
			refusal: null,
		});
		show(page({ action: "continue_payment" }));
		actor.send({ type: "RETRY" });
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view().footer.kind).toBe("checkout");
		expect(startPayment).toHaveBeenCalledOnce();
	});

	it("a refusal keeps Phoenix's detail and retries by hand", async () => {
		const { actor, startPayment, view } = harness(page());
		startPayment
			.mockResolvedValueOnce({ ok: false, error: "The workshop is full." })
			.mockImplementationOnce(() => new Promise(() => {}));
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view()).toEqual({
			footer: { kind: "retry", label: "Try again", busy: false },
			refusal: "The workshop is full.",
		});
		actor.send({ type: "RETRY" });
		actor.send({ type: "RETRY" });
		expect(view()).toEqual({
			footer: { kind: "retry", label: "Try again", busy: true },
			refusal: "The workshop is full.",
		});
		await settle();
		expect(startPayment).toHaveBeenCalledTimes(2);
	});

	it("an unexpected failure shows only fixed copy", async () => {
		const { actor, view } = harness(page(), async () => {
			throw new Error("cs_test_secret must not render");
		});
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view().refusal).toBe(START_FAILED);
		expect(JSON.stringify(actor.getSnapshot().context)).not.toContain(
			"cs_test_secret",
		);
	});

	it("a view change mid-POST never cancels the start, so its refusal still shows", async () => {
		const start = deferred<IntakePaymentStart>();
		const { actor, view, show } = harness(page(), () => start.promise);
		actor.send({ type: "MOUNTED" });
		show(page({ state: "full", action: "check_again" }));
		start.resolve({ ok: false, error: "The workshop is full." });
		await settle();
		expect(view()).toEqual({
			footer: { kind: "refresh", inProgress: false },
			refusal: "The workshop is full.",
		});
	});

	it("once the view leaves payment the session is dropped, and a returning payment action is started by hand", async () => {
		const { actor, startPayment, view, show } = harness(page());
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view().footer.kind).toBe("checkout");

		show(inProgress());
		expect(actor.getSnapshot().context.session).toBeNull();
		show(page());
		expect(view().footer).toEqual({
			kind: "retry",
			label: "Pay for your place",
			busy: false,
		});
		expect(startPayment).toHaveBeenCalledOnce();

		actor.send({ type: "RETRY" });
		await settle();
		expect(view().footer.kind).toBe("checkout");
		expect(startPayment).toHaveBeenCalledTimes(2);
	});

	it("a hosted redirect keeps the loading line", async () => {
		const { actor, view } = harness(page(), async () => undefined);
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view().footer).toEqual({ kind: "loading" });
	});

	it("starts automatically the first time a later view asks for payment", async () => {
		const { actor, startPayment, show } = harness(
			page({ state: "full", action: "check_again" }),
		);
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(startPayment).not.toHaveBeenCalled();
		show(page());
		await settle();
		expect(startPayment).toHaveBeenCalledOnce();
	});

	it.each([
		["confirm", { state: "confirm", action: "confirm" }, { kind: "confirm" }],
		[
			"check_again",
			{ state: "full", action: "check_again" },
			{ kind: "refresh", inProgress: false },
		],
		[
			"none",
			{ state: "paid", action: "none" },
			{ kind: "refresh", inProgress: false },
		],
	] as const)("%s never starts a payment", async (_, overrides, footer) => {
		const { actor, startPayment, view } = harness(page(overrides));
		actor.send({ type: "MOUNTED" });
		actor.send({ type: "RETRY" });
		await settle();
		expect(startPayment).not.toHaveBeenCalled();
		expect(view().footer).toEqual(footer);
	});

	it("payment_in_progress asks Phoenix again once per view, only in the browser", () => {
		vi.useFakeTimers();
		const { actor, refresh, view, show } = harness(inProgress());
		vi.advanceTimersByTime(10_000);
		expect(refresh).not.toHaveBeenCalled();

		actor.send({ type: "MOUNTED" });
		expect(view().footer).toEqual({ kind: "refresh", inProgress: true });
		vi.advanceTimersByTime(2999);
		expect(refresh).not.toHaveBeenCalled();
		vi.advanceTimersByTime(1);
		expect(refresh).toHaveBeenCalledOnce();
		vi.advanceTimersByTime(10_000);
		expect(refresh).toHaveBeenCalledOnce();

		show(inProgress());
		vi.advanceTimersByTime(3000);
		expect(refresh).toHaveBeenCalledTimes(2);

		show(page({ state: "paid", action: "none" }));
		vi.advanceTimersByTime(10_000);
		expect(refresh).toHaveBeenCalledTimes(2);
		actor.send({ type: "REFRESH" });
		expect(refresh).toHaveBeenCalledTimes(3);
	});

	it("a stopped page discards the start's late answer and its timer", async () => {
		vi.useFakeTimers();
		const start = deferred<IntakePaymentStart>();
		const { actor, startPayment, refresh, show } = harness(
			page(),
			() => start.promise,
		);
		actor.send({ type: "MOUNTED" });
		show(inProgress());
		actor.stop();
		start.resolve(opened);
		await settle();
		vi.advanceTimersByTime(10_000);
		expect(actor.getSnapshot().context.session).toBeNull();
		expect(refresh).not.toHaveBeenCalled();
		expect(startPayment).toHaveBeenCalledOnce();
	});
});
