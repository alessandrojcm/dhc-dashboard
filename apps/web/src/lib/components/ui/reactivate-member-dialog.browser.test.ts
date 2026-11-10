/**
 * Wiring of the reactivation dialog (ALE-450): the real dialog runs
 * `reactivationMachine` over the generated TanStack queries and mutations
 * against an in-memory Phoenix, mounted per member as the member pages do.
 * The protocol's rules are asserted in `reactivation-machine.test.ts`; these
 * tests check the dialog reaches them.
 */
import { configureClient, getClient } from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { afterEach, expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import { toast } from "svelte-sonner";
import { reactivationStartWindow } from "#lib/membership/reactivation-start-window.js";
import ReactivateMemberDialogTestWrapper from "./reactivate-member-dialog.test-wrapper.svelte";

const ALICE = "11111111-1111-1111-1111-111111111111";
const BOB = "22222222-2222-2222-2222-222222222222";

const savedMethod = {
	id: "pm_sepa_saved",
	last4: "1234",
	bankCode: "37040044",
	country: "DE",
};

const money = (amount: number) => ({ amount, currency: "EUR", precision: 2 });
const amounts = {
	dueToday: money(33000),
	proratedMonthlyPrice: money(1500),
	proratedAnnualPrice: money(31500),
	monthlyFee: money(4200),
	annualFee: money(36000),
	monthlyBillingStart: "2031-03-01",
	annualBillingStart: "2032-01-07",
};

/** Every body this in-memory Phoenix answers with. */
type Payload =
	| { errors: { detail: string; code?: string } }
	| {
			data:
				| typeof amounts
				| { url: string }
				| {
						memberId: string;
						savedPaymentMethod: typeof savedMethod | null;
						membershipCoverage: { monthly: "lapsed"; annual: "lapsed" };
				  }
				| {
						memberId: string;
						paymentState: "succeeded" | "pending" | "needs_action" | "terminal";
						monthlySubscriptionId: string;
						annualSubscriptionId: string;
				  };
	  };
type Answer = { status: number; body: Payload };
type Route = "preview" | "amounts" | "reactivate" | "portal";

const ok = (data: Extract<Payload, { data: unknown }>["data"]): Answer => ({
	status: 200,
	body: { data },
});
const refused = (status: number, detail: string, code?: string): Answer => ({
	status,
	body: { errors: { detail, ...(code && { code }) } },
});

function previewOf(memberId: string, method: typeof savedMethod | null) {
	return ok({
		memberId,
		savedPaymentMethod: method,
		membershipCoverage: { monthly: "lapsed", annual: "lapsed" },
	});
}

/**
 * An in-memory Phoenix. `answers` scripts each route's replies per member
 * (default: a saved method, amounts, a succeeded charge); `hold` parks a
 * route's request until its `release` is called.
 */
function useApi(
	script: {
		answers?: Partial<Record<Route, (memberId: string) => Answer>>;
		hold?: { route: Route; memberId: string };
	} = {},
) {
	const requests: {
		route: Route;
		memberId: string;
		url: URL;
		body: unknown;
	}[] = [];
	let release: (() => void) | undefined;
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });
	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				const request =
					input instanceof Request ? input : new Request(input, init);
				const url = new URL(request.url);
				const match = url.pathname.match(
					/\/members\/([^/]+)\/(membership\/reactivation-preview\/amounts|membership\/reactivation-preview|membership\/reactivate|billing-portal)$/,
				);
				const json = ({ status, body }: Answer) =>
					new Response(JSON.stringify(body), {
						status,
						headers: { "content-type": "application/json" },
					});
				if (!match) return json(refused(404, url.pathname));
				const [, memberId = "", path] = match;
				const route: Route =
					path === "membership/reactivation-preview/amounts"
						? "amounts"
						: path === "membership/reactivation-preview"
							? "preview"
							: path === "membership/reactivate"
								? "reactivate"
								: "portal";
				const body: unknown =
					request.method === "POST"
						? await request
								.clone()
								.json()
								.catch(() => undefined)
						: undefined;
				requests.push({ route, memberId, url, body });

				if (script.hold?.route === route && script.hold.memberId === memberId)
					await new Promise<void>((resolve) => {
						release = resolve;
					});

				const scripted = script.answers?.[route];
				if (scripted) return json(scripted(memberId));
				switch (route) {
					case "preview":
						return json(previewOf(memberId, savedMethod));
					case "amounts":
						return json(ok(amounts));
					case "reactivate":
						return json(
							ok({
								memberId,
								paymentState: "succeeded",
								monthlySubscriptionId: "sub_monthly",
								annualSubscriptionId: "sub_annual",
							}),
						);
					case "portal":
						return json(ok({ url: "https://billing.stripe.test/session" }));
				}
			},
		},
	});
	return {
		requests,
		of: (route: Route) => requests.filter((entry) => entry.route === route),
		release: () => release?.(),
	};
}

afterEach(() => {
	vi.restoreAllMocks();
	// Toasts live in a module-level store that outlives each render.
	toast.dismiss();
});

async function renderDialog() {
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	});
	const onSettled = vi.fn<(memberId: string) => void>();
	const screen = await render(ReactivateMemberDialogTestWrapper, {
		members: [ALICE, BOB],
		queryClient,
		onSettled,
	});
	return { screen, onSettled, queryClient };
}

type Screen = Awaited<ReturnType<typeof renderDialog>>["screen"];

async function open(screen: Screen, memberId: string) {
	await userEvent.click(
		screen.getByRole("button", { name: `Reactivate ${memberId}` }),
	);
	await expect.element(screen.getByRole("dialog")).toBeVisible();
}

const confirmButton = (screen: Screen) =>
	screen.getByRole("button", { name: "Reactivate membership" });

test("reactivates with the operator's selection, reports the outcome and reconciles", async () => {
	const api = useApi();
	const { screen, onSettled } = await renderDialog();
	await open(screen, ALICE);

	await expect.element(screen.getByText(/ending in 1234/i)).toBeVisible();
	await userEvent.click(
		screen.getByRole("radio", { name: /defer until next january/i }),
	);
	// The amounts query follows the machine's selection.
	await expect
		.poll(() => api.of("amounts").at(-1)?.url.searchParams.get("annualFeeMode"))
		.toBe("deferred_next_year");
	await expect
		.element(screen.getByTestId("reactivation-amounts").getByText("€330.00"))
		.toBeVisible();

	await userEvent.click(confirmButton(screen));

	await expect
		.element(screen.getByText("Membership reactivated."))
		.toBeVisible();
	await expect.element(screen.getByRole("dialog")).not.toBeInTheDocument();
	expect(api.of("reactivate")).toEqual([
		expect.objectContaining({
			memberId: ALICE,
			body: {
				startDate: reactivationStartWindow().earliest.toString(),
				annualFeeMode: "deferred_next_year",
			},
		}),
	]);
	await expect.poll(() => onSettled.mock.calls).toEqual([[ALICE]]);
});

test("reports a charge awaiting the bank", async () => {
	useApi({
		answers: {
			reactivate: (memberId) =>
				ok({
					memberId,
					paymentState: "needs_action",
					monthlySubscriptionId: "sub_monthly",
					annualSubscriptionId: "sub_annual",
				}),
		},
	});
	const { screen } = await renderDialog();
	await open(screen, ALICE);

	await userEvent.click(confirmButton(screen));

	await expect
		.element(
			screen.getByText(/awaiting bank confirmation\. SEPA direct debits/i),
		)
		.toBeVisible();
	await expect.element(screen.getByRole("dialog")).not.toBeInTheDocument();
});

test("keeps the selection across a refused charge and re-sends it on retry", async () => {
	let attempts = 0;
	const api = useApi({
		answers: {
			reactivate: (memberId) => {
				attempts += 1;
				return attempts === 1
					? refused(502, "Stripe membership reactivation failed")
					: ok({
							memberId,
							paymentState: "pending",
							monthlySubscriptionId: "sub_monthly",
							annualSubscriptionId: "sub_annual",
						});
			},
		},
	});
	const { screen, onSettled } = await renderDialog();
	await open(screen, ALICE);
	await userEvent.click(
		screen.getByRole("radio", { name: /defer until next january/i }),
	);

	await userEvent.click(confirmButton(screen));
	await expect
		.element(screen.getByText("Stripe membership reactivation failed"))
		.toBeVisible();
	await expect
		.element(screen.getByRole("radio", { name: /defer until next january/i }))
		.toBeChecked();
	expect(onSettled).not.toHaveBeenCalled();

	await userEvent.click(confirmButton(screen));
	await expect.element(screen.getByRole("dialog")).not.toBeInTheDocument();

	const [first, second] = api.of("reactivate");
	expect(second?.body).toEqual(first?.body);
	expect(first?.body).toMatchObject({ annualFeeMode: "deferred_next_year" });
});

test("keeps the form usable when the amounts preview fails", async () => {
	useApi({ answers: { amounts: () => refused(502, "Cost preview failed") } });
	const { screen } = await renderDialog();
	await open(screen, ALICE);

	await expect.element(screen.getByText(/ending in 1234/i)).toBeVisible();
	await expect.element(confirmButton(screen)).toBeEnabled();
	await expect
		.element(screen.getByTestId("reactivation-amounts"))
		.not.toBeInTheDocument();
});

test("opens the billing portal for a member with no saved method", async () => {
	const opened = vi.spyOn(window, "open").mockReturnValue(null);
	const api = useApi({
		answers: { preview: (memberId) => previewOf(memberId, null) },
	});
	const { screen } = await renderDialog();
	await open(screen, ALICE);

	await expect.element(confirmButton(screen)).toBeDisabled();
	await userEvent.click(
		screen.getByRole("button", { name: /billing portal/i }),
	);

	await expect
		.poll(() => opened.mock.calls)
		.toEqual([
			["https://billing.stripe.test/session", "_blank", "noopener,noreferrer"],
		]);
	expect(api.of("portal")).toHaveLength(1);
	expect(api.of("amounts")).toHaveLength(0);
});

test("switches to the billing portal when Phoenix finds no saved method at submission", async () => {
	useApi({
		answers: {
			reactivate: () =>
				refused(422, "No saved payment method", "no_saved_payment_method"),
		},
	});
	const { screen } = await renderDialog();
	await open(screen, ALICE);

	await userEvent.click(confirmButton(screen));

	await expect
		.element(screen.getByText(/no saved SEPA payment details to charge/i))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: /billing portal/i }))
		.toBeVisible();
});

test("stays open while the charge is being submitted", async () => {
	const api = useApi({ hold: { route: "reactivate", memberId: ALICE } });
	const { screen } = await renderDialog();
	await open(screen, ALICE);

	await userEvent.click(confirmButton(screen));
	await expect
		.element(screen.getByRole("button", { name: /confirming/i }))
		.toBeDisabled();
	await userEvent.keyboard("{Escape}");
	await expect.element(screen.getByRole("dialog")).toBeVisible();

	api.release();
	await expect.element(screen.getByRole("dialog")).not.toBeInTheDocument();
});

test("a previous member's late lookup never reaches the next member's dialog", async () => {
	const api = useApi({
		hold: { route: "preview", memberId: ALICE },
		answers: {
			preview: (memberId) =>
				previewOf(memberId, memberId === ALICE ? savedMethod : null),
		},
	});
	const { screen } = await renderDialog();
	await open(screen, ALICE);
	await expect
		.element(screen.getByText(/checking saved payment method/i))
		.toBeVisible();

	await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
	await expect.element(screen.getByRole("dialog")).not.toBeInTheDocument();
	await open(screen, BOB);
	await expect
		.element(screen.getByText(/no saved SEPA payment details to charge/i))
		.toBeVisible();

	api.release();
	await expect.poll(() => api.of("preview").length).toBe(2);
	await expect
		.element(screen.getByText(/no saved SEPA payment details to charge/i))
		.toBeVisible();
	await expect
		.element(screen.getByText(/ending in 1234/i))
		.not.toBeInTheDocument();
});
