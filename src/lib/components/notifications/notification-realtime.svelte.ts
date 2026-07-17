import { Socket as PhoenixSocket } from "phoenix";
import type { Channel, Socket } from "phoenix";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Notification realtime bridge for NotificationCenter.
 *
 * Replaces the former Supabase Realtime `postgres_changes` subscription with
 * an authenticated, per-user Phoenix Channel. The channel carries only a
 * best-effort `notification_created` invalidation signal; notification data,
 * pagination, and unread counts remain owned by the Phoenix HTTP API.
 *
 * The bridge is best-effort: connection, authentication, join, and reconnect
 * failures never throw to the caller. They emit diagnostic warnings and let
 * Phoenix's normal reconnect/rejoin behavior recover. HTTP queries and
 * mutations remain usable regardless of realtime state.
 */

export type InvalidateNotifications = () => void;

/**
 * Factory that constructs a Phoenix `Socket`. Injected so tests can substitute
 * the client boundary without importing the real `phoenix` package.
 */
export type SocketFactory = (
	url: string,
	options: { authToken: string },
) => Socket;

export interface NotificationRealtimeConfig {
	/** Public Phoenix WebSocket socket URL, e.g. `wss://host/socket`. */
	socketUrl: string;
	/** Supabase browser client used to read the session and auth changes. */
	supabase: SupabaseClient;
	/** Invalidates the Notifications infinite-query key (authoritative refetch). */
	invalidate: InvalidateNotifications;
	/** Constructs the Phoenix Socket. Defaults to the real `phoenix` client. */
	createSocket?: SocketFactory;
}

export interface NotificationRealtimeHandle {
	/** Tear down auth listener, leave channel, and disconnect socket. Idempotent. */
	destroy: () => void;
}

const NOTIFICATION_CREATED_EVENT = "notification_created";

const defaultCreateSocket: SocketFactory = (url, options) => {
	// Imported at module top-level so Vite bundles the real `phoenix` client.
	// Tests inject a substitute via `createSocket`, so this default never runs
	// under test.
	return new PhoenixSocket(url, options);
};

function warn(context: string, error: unknown): void {
	console.warn(`NotificationCenter realtime: ${context}`, error);
}

/**
 * Connect a Phoenix Socket, join the user's Notification topic, and wire
 * Supabase auth lifecycle (token refresh, sign-out) to the connection.
 *
 * Returns a handle whose `destroy()` removes the auth listener, leaves the
 * channel, and disconnects the socket. All realtime failures are swallowed
 * and logged; `invalidate` is only ever called as a best-effort refetch
 * trigger, never as an error path.
 */
export function connectNotificationRealtime(
	config: NotificationRealtimeConfig,
): NotificationRealtimeHandle {
	const {
		socketUrl,
		supabase,
		invalidate,
		createSocket = defaultCreateSocket,
	} = config;

	let socket: Socket | null = null;
	let channel: Channel | null = null;
	let authSubscription: { unsubscribe: () => void } | null = null;
	let destroyed = false;

	function invalidateSafely(): void {
		try {
			invalidate();
		} catch (error) {
			warn("invalidation callback threw", error);
		}
	}

	function teardownChannel(): void {
		if (!channel) return;
		const current = channel;
		channel = null;
		try {
			current
				.leave()
				.receive("error", (reason) => warn("channel leave rejected", reason));
		} catch (error) {
			warn("channel leave threw", error);
		}
	}

	function disconnectSocket(): void {
		if (!socket) return;
		const current = socket;
		socket = null;
		try {
			current.disconnect();
		} catch (error) {
			warn("socket disconnect threw", error);
		}
	}

	function unsubscribeAuth(): void {
		if (!authSubscription) return;
		const current = authSubscription;
		authSubscription = null;
		try {
			current.unsubscribe();
		} catch (error) {
			warn("auth listener unsubscribe threw", error);
		}
	}

	/**
	 * Build a fresh socket + channel for the supplied access token / user id.
	 * Replaces any existing connection wholesale: per the integration spec, a
	 * refreshed token requires a new `Socket` instance because `authToken` is
	 * a string captured at construction, not a live callback.
	 */
	function connectWithToken(accessToken: string, userId: string): void {
		if (destroyed) return;
		if (!accessToken || !userId) return;

		teardownChannel();
		disconnectSocket();

		let newSocket: Socket;
		try {
			newSocket = createSocket(socketUrl, { authToken: accessToken });
		} catch (error) {
			warn("socket construction failed", error);
			return;
		}
		socket = newSocket;

		try {
			newSocket.onError((reason) => warn("socket error", reason));
		} catch (error) {
			warn("socket onError wiring failed", error);
		}

		try {
			newSocket.connect();
		} catch (error) {
			warn("socket connect failed", error);
			// Leave socket reference so a later token refresh can replace it;
			// Phoenix would otherwise auto-reconnect, but construction may have
			// partially failed in a test boundary.
			return;
		}

		let newChannel: Channel;
		try {
			newChannel = newSocket.channel(`notifications:${userId}`);
		} catch (error) {
			warn("channel construction failed", error);
			return;
		}
		channel = newChannel;

		try {
			newChannel.on(NOTIFICATION_CREATED_EVENT, () => invalidateSafely());
		} catch (error) {
			warn("channel.on wiring failed", error);
		}

		// Rejoin (and initial join) invalidation: recovers events missed while
		// disconnected by refetching authoritative state. The `ok` hook fires
		// on the initial join and on every successful rejoin after an error.
		try {
			newChannel
				.join()
				.receive("ok", () => invalidateSafely())
				.receive("error", (reason) => warn("channel join rejected", reason))
				.receive("timeout", () => warn("channel join timed out", undefined));
		} catch (error) {
			warn("channel join threw", error);
		}
	}

	async function init(): Promise<void> {
		try {
			const { data, error } = await supabase.auth.getSession();
			if (error) {
				warn("getSession error", error);
			}
			const accessToken = data.session?.access_token;
			const userId = data.session?.user.id;
			if (accessToken && userId) {
				connectWithToken(accessToken, userId);
			}
		} catch (error) {
			warn("initial session read failed", error);
		}
		if (destroyed) return;

		try {
			const { data } = supabase.auth.onAuthStateChange((event, session) => {
				if (destroyed) return;
				if (event === "TOKEN_REFRESHED") {
					const accessToken = session?.access_token;
					const userId = session?.user.id;
					if (accessToken && userId) {
						connectWithToken(accessToken, userId);
					}
				} else if (event === "SIGNED_OUT") {
					unsubscribeAuth();
					teardownChannel();
					disconnectSocket();
				}
			});
			if (destroyed) {
				data.subscription.unsubscribe();
			} else {
				authSubscription = data.subscription;
			}
		} catch (error) {
			warn("auth listener registration failed", error);
		}
	}

	// Fire and forget; all failures are swallowed inside `init`.
	void init();

	return {
		destroy() {
			if (destroyed) return;
			destroyed = true;
			unsubscribeAuth();
			teardownChannel();
			disconnectSocket();
		},
	};
}
