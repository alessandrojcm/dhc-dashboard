<script lang="ts" module>
import type { PushEnvironment } from "$lib/notifications/web-push/availability";
import type {
	PushBrowser,
	PushServer,
} from "$lib/notifications/web-push/workflow";

/**
 * Everything the toggle needs from outside the component. Defaults are the
 * real browser Push API and the Phoenix API; browser tests pass fakes.
 */
export type WebPushToggleDeps = {
	/** Resolves the page's push manager, or `null` when there is no worker. */
	browser: () => Promise<PushBrowser | null>;
	server: PushServer;
	environment: (serverEnabled: boolean) => PushEnvironment;
	userAgent: string;
};
</script>

<script lang="ts">
import { onMount, untrack } from "svelte";
import {
	notificationsPushConfigOptions,
	notificationsPushSubscribeMutation,
	notificationsPushUnsubscribeMutation,
} from "@dhc/api-client";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { readPushEnvironment } from "$lib/notifications/web-push/availability";
import { browserPushManager } from "$lib/notifications/web-push/browser";
import {
	determinePushStatus,
	disablePush,
	enablePush,
	forgetPushSubscription,
	type PushStatus,
} from "$lib/notifications/web-push/workflow";
import { Switch } from "$lib/components/ui/switch";

let { deps: providedDeps }: { deps?: Partial<WebPushToggleDeps> } = $props();

// ALE-299. The component owns only presentation and the busy flag; every
// decision is in `$lib/notifications/web-push/*`, where it is unit-tested.
//
// The Phoenix adapter goes through the generated TanStack helpers (the
// repo's rule for direct Phoenix client calls) and is built only when a test
// has not injected its own `server`, so component tests need no QueryClient.
// Read once on purpose: `createMutation` must run during component init.
const server: PushServer =
	untrack(() => providedDeps?.server) ?? apiPushServer();

const deps = $derived<WebPushToggleDeps>({
	browser: browserPushManager,
	environment: (serverEnabled) => readPushEnvironment(window, serverEnabled),
	// `navigator` is absent during SSR; the value is only read after mount.
	userAgent: globalThis.navigator?.userAgent.slice(0, 512) ?? "",
	...providedDeps,
	server,
});

function apiPushServer(): PushServer {
	const queryClient = useQueryClient();
	const subscribe = createMutation(() => notificationsPushSubscribeMutation());
	const unsubscribe = createMutation(() =>
		notificationsPushUnsubscribeMutation(),
	);

	return {
		config: async () => {
			try {
				const response = await queryClient.fetchQuery(
					notificationsPushConfigOptions(),
				);
				return response.data;
			} catch {
				return null;
			}
		},
		register: async (subscription, userAgent) => {
			if (!subscription.keys) return false;
			try {
				await subscribe.mutateAsync({
					body: {
						endpoint: subscription.endpoint,
						expirationTime: subscription.expirationTime ?? null,
						keys: subscription.keys,
						userAgent,
					},
				});
				return true;
			} catch {
				return false;
			}
		},
		unregister: async (endpoint) => {
			try {
				await unsubscribe.mutateAsync({ body: { endpoint } });
				return true;
			} catch {
				return false;
			}
		},
	};
}

let status = $state<PushStatus>({ kind: "loading" });
let busy = $state(false);
let browser: PushBrowser | null = null;

async function refresh() {
	browser = await deps.browser().catch(() => null);
	status = await determinePushStatus({
		browser,
		server: deps.server,
		environment: deps.environment,
		userAgent: deps.userAgent,
	});
}

onMount(() => {
	void refresh();
});

async function setEnabled(enabled: boolean) {
	if (busy || !browser) return;
	if (status.kind !== "on" && status.kind !== "off") return;
	busy = true;
	try {
		status = enabled
			? await enablePush({
					browser,
					server: deps.server,
					vapidPublicKey: status.vapidPublicKey,
					userAgent: deps.userAgent,
				})
			: await disablePush({
					browser,
					server: deps.server,
					vapidPublicKey: status.vapidPublicKey,
				});
	} finally {
		busy = false;
	}
}

// The escape hatch for an existing subscription the server keeps refusing:
// the member can still silence this device, then decide again from "off".
async function turnOffFromError() {
	if (busy) return;
	busy = true;
	try {
		await forgetPushSubscription({ browser, server: deps.server });
	} finally {
		busy = false;
	}
	await refresh();
}

const explanation = $derived.by(() => {
	switch (status.kind) {
		case "loading":
			return "Checking this device…";
		case "server-disabled":
			return "Push notifications aren't available on this deployment.";
		case "ios-install-required":
			return "On iPhone and iPad, add the dashboard to your Home Screen (Share → Add to Home Screen) and open it from there to turn on push notifications.";
		case "unsupported":
			return "This browser doesn't support push notifications.";
		case "denied":
			return "Notifications are blocked for this site. Allow them in your browser's site settings to turn push notifications back on.";
		case "off":
			return (
				status.warning ??
				"Get notified on this device even when the dashboard is closed."
			);
		case "on":
			return "This device gets notifications even when the dashboard is closed.";
		case "error":
			return status.message;
	}
});

const toggleable = $derived(status.kind === "on" || status.kind === "off");
</script>

<div
	class="flex items-start justify-between gap-3 px-4 py-3"
	data-testid="web-push-toggle"
	data-status={status.kind}
>
	<div class="min-w-0 flex-1">
		<p class="m-0 text-sm font-medium">Push notifications</p>
		<p class="m-0 text-xs text-muted-foreground">{explanation}</p>
		{#if status.kind === "error"}
			<div class="mt-1 flex gap-3">
				<button
					type="button"
					class="text-xs text-primary bg-transparent border-none cursor-pointer p-0"
					onclick={() => void refresh()}
				>
					Try again
				</button>
				{#if status.subscribed}
					<button
						type="button"
						class="text-xs text-primary bg-transparent border-none cursor-pointer p-0"
						disabled={busy}
						onclick={() => void turnOffFromError()}
					>
						Turn off on this device
					</button>
				{/if}
			</div>
		{/if}
	</div>
	{#if toggleable}
		<!-- Keyed on the status object so a failed toggle snaps the switch back
		     to what the workflow decided instead of trusting its local state. -->
		{#key status}
			<Switch
				checked={status.kind === "on"}
				disabled={busy}
				aria-label="Push notifications on this device"
				onCheckedChange={(checked) => void setEnabled(checked)}
			/>
		{/key}
	{/if}
</div>
