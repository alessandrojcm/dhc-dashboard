import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import WebPushToggle, { type WebPushToggleDeps } from "./WebPushToggle.svelte";
import type { PushEnvironment } from "$lib/notifications/web-push/availability";
import type {
	BrowserSubscription,
	PushBrowser,
} from "$lib/notifications/web-push/workflow";

// ALE-299: the toggle's job is to explain each state without prompting and to
// hand a click to the workflow. The Push API and Phoenix are faked; the
// workflow's own decisions are covered in `workflow.test.ts`.

const vapid = "BAEC";

function environment(
	overrides: Partial<PushEnvironment> = {},
): WebPushToggleDeps["environment"] {
	return (serverEnabled) => ({
		serverEnabled,
		hasServiceWorker: true,
		hasPushManager: true,
		hasNotification: true,
		permission: "default",
		isIOS: false,
		isStandalone: false,
		...overrides,
	});
}

function subscription(endpoint: string): BrowserSubscription {
	return {
		endpoint,
		applicationServerKey: null,
		toJSON: () => ({ endpoint, keys: { p256dh: "p", auth: "a" } }),
		unsubscribe: vi.fn(async () => true),
	};
}

function deps(
	overrides: Partial<WebPushToggleDeps> = {},
	browser: PushBrowser | null = {
		getSubscription: vi.fn(async () => null),
		subscribe: vi.fn(async () => subscription("https://push.example/new")),
	},
): WebPushToggleDeps {
	return {
		browser: async () => browser,
		server: {
			config: vi.fn(async () => ({ enabled: true, vapidPublicKey: vapid })),
			register: vi.fn(async () => true),
			unregister: vi.fn(async () => true),
		},
		environment: environment(),
		userAgent: "Test UA",
		...overrides,
	};
}

test("offers the switch off and never prompts until it is clicked", async () => {
	const browser: PushBrowser = {
		getSubscription: vi.fn(async () => null),
		subscribe: vi.fn(async () => subscription("https://push.example/new")),
	};
	const d = deps({}, browser);
	const screen = await render(WebPushToggle, { deps: d });

	const toggle = screen.getByRole("switch", { name: /push notifications/i });
	await expect.element(toggle).toBeVisible();
	await expect.element(toggle).toHaveAttribute("aria-checked", "false");
	await expect
		.element(screen.getByText(/even when the dashboard is closed/i))
		.toBeVisible();
	expect(browser.subscribe).not.toHaveBeenCalled();

	await userEvent.click(toggle);

	await expect
		.element(screen.getByRole("switch", { name: /push notifications/i }))
		.toHaveAttribute("aria-checked", "true");
	expect(browser.subscribe).toHaveBeenCalledTimes(1);
	expect(d.server.register).toHaveBeenCalledWith(
		{
			endpoint: "https://push.example/new",
			keys: { p256dh: "p", auth: "a" },
		},
		"Test UA",
	);
});

test("shows on for a browser that already holds a subscription and turns it off", async () => {
	const existing = subscription("https://push.example/existing");
	const d = deps(
		{},
		{
			getSubscription: vi.fn(async () => existing),
			subscribe: vi.fn(),
		},
	);
	const screen = await render(WebPushToggle, { deps: d });

	const toggle = screen.getByRole("switch", { name: /push notifications/i });
	await expect.element(toggle).toHaveAttribute("aria-checked", "true");

	await userEvent.click(toggle);

	await expect
		.element(screen.getByRole("switch", { name: /push notifications/i }))
		.toHaveAttribute("aria-checked", "false");
	expect(d.server.unregister).toHaveBeenCalledWith(
		"https://push.example/existing",
	);
	expect(existing.unsubscribe).toHaveBeenCalledTimes(1);
});

test("explains a denied permission without offering a switch", async () => {
	const screen = await render(WebPushToggle, {
		deps: deps({ environment: environment({ permission: "denied" }) }),
	});

	await expect
		.element(screen.getByText(/blocked for this site/i))
		.toBeVisible();
	await expect
		.element(screen.getByRole("switch", { name: /push notifications/i }))
		.not.toBeInTheDocument();
});

test("tells iOS Safari users to install the app first", async () => {
	const screen = await render(WebPushToggle, {
		deps: deps(
			{
				environment: environment({
					isIOS: true,
					isStandalone: false,
					hasPushManager: false,
				}),
			},
			null,
		),
	});

	await expect.element(screen.getByText(/add to home screen/i)).toBeVisible();
	await expect
		.element(screen.getByTestId("web-push-toggle"))
		.toHaveAttribute("data-status", "ios-install-required");
});

test("says push is unavailable when the deployment has no keys", async () => {
	const screen = await render(WebPushToggle, {
		deps: deps({
			server: {
				config: vi.fn(async () => ({ enabled: false, vapidPublicKey: null })),
				register: vi.fn(async () => true),
				unregister: vi.fn(async () => true),
			},
		}),
	});

	await expect
		.element(screen.getByText(/aren't available on this deployment/i))
		.toBeVisible();
});

test("a rejected registration snaps the switch back and offers a retry", async () => {
	const created = subscription("https://push.example/new");
	const d = deps(
		{
			server: {
				config: vi.fn(async () => ({ enabled: true, vapidPublicKey: vapid })),
				register: vi.fn(async () => false),
				unregister: vi.fn(async () => true),
			},
		},
		{
			getSubscription: vi.fn(async () => null),
			subscribe: vi.fn(async () => created),
		},
	);
	const screen = await render(WebPushToggle, { deps: d });

	await userEvent.click(
		screen.getByRole("switch", { name: /push notifications/i }),
	);

	await expect
		.element(screen.getByText(/couldn't save this device/i))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: /try again/i }))
		.toBeVisible();
	expect(created.unsubscribe).toHaveBeenCalledTimes(1);
});

test("an unconfirmed existing subscription can still be turned off from the centre", async () => {
	const existing = subscription("https://push.example/existing");
	const d = deps(
		{
			server: {
				config: vi.fn(async () => ({ enabled: true, vapidPublicKey: vapid })),
				register: vi.fn(async () => false),
				unregister: vi.fn(async () => true),
			},
		},
		{
			getSubscription: vi.fn(async () => existing),
			subscribe: vi.fn(),
		},
	);
	const screen = await render(WebPushToggle, { deps: d });

	await expect
		.element(screen.getByText(/couldn't confirm this device/i))
		.toBeVisible();

	await userEvent.click(
		screen.getByRole("button", { name: /turn off on this device/i }),
	);

	expect(d.server.unregister).toHaveBeenCalledWith(
		"https://push.example/existing",
	);
	expect(existing.unsubscribe).toHaveBeenCalledTimes(1);
});
