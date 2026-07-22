import { Socket as PhoenixSocket } from "phoenix";
import type { Channel, Socket } from "phoenix";

/**
 * Notification realtime bridge for NotificationCenter (ALE-164).
 *
 * Replaces the Supabase-Realtime-backed bridge with a Phoenix-Session-backed
 * one. The browser can no longer read the HTTP-only `_dhc_session` cookie to
 * pass it as a Phoenix JS `authToken`, and `new WebSocket(url, protocols)`
 * has no `withCredentials` so a cross-origin socket cannot send the cookie.
 * Instead, the bridge fetches a short-lived, JS-readable socket token from
 * `GET /api/auth/socket-token` (credentialed, so the cookie is sent) and
 * passes it as `authToken`. The token is short-lived, so a reconnect after a
 * long disconnect re-fetches a fresh one.
 *
 * The channel carries only a best-effort `notification_created` invalidation
 * signal; notification data, pagination, and unread counts remain owned by
 * the Phoenix HTTP API.
 *
 * The bridge is best-effort: connection, authentication, join, and reconnect
 * failures never throw to the caller. They emit diagnostic warnings and let
 * Phoenix's normal reconnect/rejoin behavior recover. HTTP queries and
 * mutations remain usable regardless of realtime state.
 */

export type InvalidateNotifications = () => void;

/**
 * Fetches a short-lived Phoenix socket token. Returns `null` on any failure
 * so the bridge can skip the connection attempt; the caller's HTTP queries
 * remain usable.
 */
export type SocketTokenFetcher = () => Promise<string | null>;

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
	/** Fetches a short-lived Phoenix socket token (via the session cookie). */
	getSocketToken: SocketTokenFetcher;
	/** Invalidates the Notifications infinite-query key (authoritative refetch). */
	invalidate: InvalidateNotifications;
	/** Constructs the Phoenix Socket. Defaults to the real `phoenix` client. */
	createSocket?: SocketFactory;
}

export interface NotificationRealtimeHandle {
	/** Tear down channel and disconnect socket. Idempotent. */
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
 * Connect a Phoenix Socket, join the user's Notification topic, and wire the
 * token lifecycle. The bridge re-fetches a socket token on every connect
 * (initial and reconnect) because the token is short-lived.
 *
 * Returns a handle whose `destroy()` leaves the channel and disconnects the
 * socket. All realtime failures are swallowed and logged; `invalidate` is
 * only ever called as a best-effort refetch trigger, never as an error path.
 *
 * The `userId` (topic suffix) is read from the decoded socket token —
 * Phoenix assigns `current_user.sub` on connect, and the channel join
 * authorizes the topic against that sub. The browser does not need to know
 * its own user id here; it learns the topic from the server's join response.
 */
export function connectNotificationRealtime(
	config: NotificationRealtimeConfig,
): NotificationRealtimeHandle {
	const {
		socketUrl,
		getSocketToken,
		invalidate,
		createSocket = defaultCreateSocket,
	} = config;

	let socket: Socket | null = null;
	let channel: Channel | null = null;
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

	/**
	 * Fetch a fresh socket token and connect. Replaces any existing connection
	 * wholesale: a reconnect after a long disconnect needs a fresh token
	 * because the socket-token validity window is short.
	 */
	async function connectWithFreshToken(): Promise<void> {
		if (destroyed) return;

		let token: string | null;
		try {
			token = await getSocketToken();
		} catch (error) {
			warn("socket token fetch threw", error);
			return;
		}
		if (destroyed || !token) return;

		teardownChannel();
		disconnectSocket();

		let newSocket: Socket;
		try {
			newSocket = createSocket(socketUrl, { authToken: token });
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
			return;
		}

		// The channel topic is `notifications:<sub>`. The browser does not know
		// its own sub (the socket token is opaque), so it joins a generic
		// `notifications:self` topic and relies on the server's join/3 to
		// authorize against `socket.assigns.current_user.sub`. The channel
		// module already rejects any mismatched topic suffix.
		let newChannel: Channel;
		try {
			newChannel = newSocket.channel("notifications:self");
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

	// Fire and forget; all failures are swallowed inside `connectWithFreshToken`.
	void connectWithFreshToken();

	return {
		destroy() {
			if (destroyed) return;
			destroyed = true;
			teardownChannel();
			disconnectSocket();
		},
	};
}
