import { Socket as PhoenixSocket } from "phoenix";
import type { PhoenixPayload } from "phoenix";

/**
 * Notification realtime bridge for NotificationCenter (ALE-164).
 *
 * Replaces the Supabase-Realtime-backed bridge with a Phoenix-Session-backed
 * one. The browser can no longer read the HTTP-only `_dhc_session` cookie to
 * pass it as a Phoenix JS `authToken`, and `new WebSocket(url, protocols)`
 * has no `withCredentials` so a cross-origin socket cannot send the cookie.
 * Instead, the bridge fetches a short-lived, JS-readable socket token from
 * `GET /api/auth/socket-token` (credentialed, so the cookie is sent) and
 * passes it as `authToken`.
 *
 * Socket tokens are valid for 60 seconds, and Phoenix JS's own reconnect loop
 * reuses the original `authToken`, so the bridge owns recovery (ALE-337).
 * Sockets are constructed with a `reconnectAfterMs` that never fires in
 * practice, so Phoenix never reconnects by itself. When the live socket
 * errors or closes, the bridge leaves its channel, disconnects it, waits a
 * bounded backoff, fetches a fresh token, and connects a new socket. Every
 * successful (re)join calls `invalidate()` so events missed while
 * disconnected are recovered by an authoritative refetch, and resets the
 * backoff. A token fetch that hangs past a timeout is abandoned and retried;
 * a token that resolves after `destroy()` or after a newer attempt has
 * started is dropped. A retired socket that revives itself anyway (Phoenix's
 * heartbeat-timeout or `pageshow` paths) is disconnected again on its next
 * lifecycle event.
 *
 * The channel carries only a best-effort `notification_created` invalidation
 * signal; notification data, pagination, and unread counts remain owned by
 * the Phoenix HTTP API.
 *
 * The bridge is best-effort: connection, authentication, join, and reconnect
 * failures never throw to the caller. They emit diagnostic warnings and are
 * retried with backoff (a failed or empty token fetch included). Channel
 * rejoin on a still-connected socket is left to Phoenix: it needs no token,
 * only schedules while the socket is connected, and the bridge leaves the
 * channel before retiring its socket, so the two never compete. HTTP queries and
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
export interface RealtimePush {
	receive(
		status: string,
		callback: (response: PhoenixPayload) => void,
	): RealtimePush;
	send(timeout?: number): RealtimePush;
}

export interface RealtimeChannel {
	readonly topic: string;
	join(timeout?: number): RealtimePush;
	leave(timeout?: number): RealtimePush;
	on(
		event: string,
		callback: (payload: PhoenixPayload, ref?: string) => void,
	): string;
}

export interface RealtimeSocket {
	connect(): void;
	disconnect(callback?: () => void, code?: number, reason?: string): void;
	channel(topic: string): RealtimeChannel;
	onError(callback: (reason?: string) => void): string;
	onClose(callback: () => void): string;
	onOpen(callback: () => void): string;
}

export interface RealtimeSocketOptions {
	authToken: string;
	/**
	 * Phoenix's own reconnect delay. The bridge owns recovery, so this keeps
	 * Phoenix's reconnect timer from firing within any realistic page life.
	 */
	reconnectAfterMs: (tries: number) => number;
}

export type SocketFactory = (
	url: string,
	options: RealtimeSocketOptions,
) => RealtimeSocket;

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

/**
 * Delay before each consecutive reconnect attempt. The last entry is the
 * ceiling, so a failing token endpoint is hit at most every 30 seconds.
 */
const RECONNECT_BACKOFF_MS = [1_000, 2_000, 5_000, 10_000, 30_000] as const;

/** A token fetch that hasn't settled by now is abandoned and retried. */
const TOKEN_FETCH_TIMEOUT_MS = 10_000;

/**
 * Largest delay `setTimeout` honours (~24.8 days). Larger values, including
 * `Infinity`, overflow and fire immediately, so this is the "never" handed to
 * Phoenix's reconnect timer.
 */
const NEVER_MS = 2_147_483_647;

const defaultCreateSocket: SocketFactory = (url, options) => {
	// Imported at module top-level so Vite bundles the real `phoenix` client.
	// Tests inject a substitute via `createSocket`, so this default never runs
	// under test.
	return new PhoenixSocket(url, options);
};

function warn(context: string, cause: unknown): void {
	console.warn(`NotificationCenter realtime: ${context}`, cause);
}

/**
 * Connect a Phoenix Socket, join the user's Notification topic, and keep it
 * connected. Every connect (initial and recovery) fetches a fresh socket
 * token because the token is short-lived; a socket error or close replaces
 * the socket after a bounded backoff.
 *
 * Returns a handle whose `destroy()` cancels any pending reconnect, leaves
 * the channel, and disconnects the socket. All realtime failures are
 * swallowed and logged; `invalidate` is only ever called as a best-effort
 * refetch trigger, never as an error path.
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

	let socket: RealtimeSocket | null = null;
	let channel: RealtimeChannel | null = null;
	let destroyed = false;
	/** Incremented per connect attempt; a stale attempt drops its results. */
	let attempt = 0;
	/** Attempts since the last successful join; indexes the backoff. */
	let attemptsSinceJoin = 0;
	let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

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
	 * Drop the current connection and schedule a fresh-token connect after the
	 * next backoff delay. Disconnecting the dead socket also resets Phoenix's
	 * own reconnect timer, so the two loops never compete.
	 */
	function scheduleReconnect(): void {
		if (destroyed || reconnectTimer) return;
		teardownChannel();
		disconnectSocket();
		const delay =
			RECONNECT_BACKOFF_MS[
				Math.min(attemptsSinceJoin, RECONNECT_BACKOFF_MS.length - 1)
			];
		attemptsSinceJoin += 1;
		reconnectTimer = setTimeout(() => {
			reconnectTimer = null;
			void connectWithFreshToken();
		}, delay);
	}

	/**
	 * Fetch a fresh socket token and connect. Replaces any existing connection
	 * wholesale: a reconnect after a long disconnect needs a fresh token
	 * because the socket-token validity window is short.
	 */
	async function connectWithFreshToken(): Promise<void> {
		if (destroyed) return;
		const current = ++attempt;
		const isStale = () => destroyed || current !== attempt;

		// A hung fetch would otherwise stall recovery forever. Abandoning it
		// supersedes this attempt, so its late result is dropped below.
		const fetchTimeout = setTimeout(() => {
			if (isStale()) return;
			attempt += 1;
			warn("socket token fetch timed out", undefined);
			scheduleReconnect();
		}, TOKEN_FETCH_TIMEOUT_MS);

		let token: string | null;
		try {
			token = await getSocketToken();
		} catch (error) {
			if (isStale()) return;
			warn("socket token fetch threw", error);
			scheduleReconnect();
			return;
		} finally {
			clearTimeout(fetchTimeout);
		}
		if (isStale()) return;
		if (!token) {
			warn("socket token unavailable", undefined);
			scheduleReconnect();
			return;
		}

		teardownChannel();
		disconnectSocket();

		let newSocket: RealtimeSocket;
		try {
			newSocket = createSocket(socketUrl, {
				authToken: token,
				reconnectAfterMs: () => NEVER_MS,
			});
		} catch (error) {
			warn("socket construction failed", error);
			scheduleReconnect();
			return;
		}
		socket = newSocket;

		// A retired socket (replaced, or its bridge destroyed) can still revive
		// itself: Phoenix's heartbeat-timeout teardown schedules a reconnect even
		// after `disconnect()`, and `pageshow` reconnects after bfcache restore.
		// Any lifecycle event from a retired socket disconnects it again.
		const isRetired = () => destroyed || socket !== newSocket;
		const retire = () => {
			try {
				newSocket.disconnect();
			} catch (error) {
				warn("retired socket disconnect threw", error);
			}
		};
		const onSocketLost = (context: string) => (reason?: string) => {
			if (isRetired()) {
				retire();
				return;
			}
			warn(context, reason);
			scheduleReconnect();
		};
		try {
			newSocket.onError(onSocketLost("socket error"));
			newSocket.onClose(onSocketLost("socket closed"));
			newSocket.onOpen(() => {
				if (isRetired()) retire();
			});
		} catch (error) {
			warn("socket lifecycle wiring failed", error);
		}

		try {
			newSocket.connect();
		} catch (error) {
			warn("socket connect failed", error);
			scheduleReconnect();
			return;
		}

		// The channel topic is `notifications:<sub>`. The browser does not know
		// its own sub (the socket token is opaque), so it joins a generic
		// `notifications:self` topic and relies on the server's join/3 to
		// authorize against `socket.assigns.current_user.sub`. The channel
		// module already rejects any mismatched topic suffix.
		let newChannel: RealtimeChannel;
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
				.receive("ok", () => {
					if (socket !== newSocket) return;
					attemptsSinceJoin = 0;
					invalidateSafely();
				})
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
			if (reconnectTimer) {
				clearTimeout(reconnectTimer);
				reconnectTimer = null;
			}
			teardownChannel();
			disconnectSocket();
		},
	};
}
