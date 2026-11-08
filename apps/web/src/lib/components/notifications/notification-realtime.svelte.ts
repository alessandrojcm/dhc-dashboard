import { Socket as PhoenixSocket } from "phoenix";
import { assign, createActor, fromPromise, setup } from "xstate";
import type { PhoenixPayload } from "phoenix";
import { authSessionSocketToken } from "@dhc/api-client";

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
 * retried with backoff (a failed or empty token fetch included), except a
 * rejected HTTP session, which ends this bridge until it is mounted again. Channel
 * rejoin on a still-connected socket is left to Phoenix: it needs no token,
 * only schedules while the socket is connected, and the bridge leaves the
 * channel before retiring its socket, so the two never compete. HTTP queries and
 * mutations remain usable regardless of realtime state.
 */

export type InvalidateNotifications = () => void;

/**
 * Fetches a short-lived Phoenix socket token. `null` is temporarily unavailable;
 * an unauthorized session ends recovery. HTTP queries remain independent.
 */
export const socketSessionUnauthorized = Symbol("socket-session-unauthorized");
export type SocketTokenFetcher = () => Promise<
	string | null | typeof socketSessionUnauthorized
>;

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
	getSocketToken?: SocketTokenFetcher;
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

const defaultGetSocketToken: SocketTokenFetcher = async () => {
	const { data, error, response } = await authSessionSocketToken();
	if (response?.status === 401) return socketSessionUnauthorized;
	return error || !data ? null : data.data.socketToken;
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
type NotificationRealtimeMachineInput = {
	socketUrl: string;
	getSocketToken: SocketTokenFetcher;
	invalidate: InvalidateNotifications;
	createSocket: SocketFactory;
};

type NotificationRealtimeMachineContext = NotificationRealtimeMachineInput & {
	socket: RealtimeSocket | null;
	channel: RealtimeChannel | null;
	attemptsSinceJoin: number;
};

type NotificationRealtimeMachineEvent =
	| { type: "SOCKET_LOST"; socket: RealtimeSocket; reason?: string }
	| { type: "CONNECTION_FAILED"; cause: unknown }
	| { type: "CHANNEL_JOINED"; socket: RealtimeSocket }
	| { type: "NOTIFICATION_CREATED"; socket: RealtimeSocket }
	| { type: "DESTROY" }
	// XState emits these for the invoked token-fetch actor. Listing them keeps
	// guards and actions type-safe while the actor remains cancellable on exit.
	| {
			type: "xstate.done.actor.fetchSocketToken";
			output: Awaited<ReturnType<SocketTokenFetcher>>;
	  }
	| { type: "xstate.error.actor.fetchSocketToken"; error: unknown };

function disconnect(socket: RealtimeSocket, context: string): void {
	try {
		socket.disconnect();
	} catch (error) {
		warn(context, error);
	}
}

function leave(channel: RealtimeChannel): void {
	try {
		channel
			.leave()
			.receive("error", (reason) => warn("channel leave rejected", reason));
	} catch (error) {
		warn("channel leave threw", error);
	}
}

/**
 * A definition is safely shared, but each connection factory below creates its
 * own actor. Its context contains every injected browser dependency and the
 * current socket/channel; no recovery state is shared between page mounts.
 */
const notificationRealtimeMachine = setup({
	// SAFETY: XState reads these placeholders as types only.
	types: {
		context: {} as NotificationRealtimeMachineContext,
		events: {} as NotificationRealtimeMachineEvent,
		input: {} as NotificationRealtimeMachineInput,
	},
	actors: {
		fetchSocketToken: fromPromise<
			Awaited<ReturnType<SocketTokenFetcher>>,
			SocketTokenFetcher
		>(async ({ input }) => input()),
	},
	delays: {
		backoff: ({ context }) =>
			RECONNECT_BACKOFF_MS[
				Math.min(context.attemptsSinceJoin, RECONNECT_BACKOFF_MS.length - 1)
			],
	},
	guards: {
		isUnauthorized: ({ event }) =>
			event.type === "xstate.done.actor.fetchSocketToken" &&
			event.output === socketSessionUnauthorized,
		hasToken: ({ event }) =>
			event.type === "xstate.done.actor.fetchSocketToken" &&
			event.output !== socketSessionUnauthorized &&
			!!event.output,
		isCurrentSocket: ({ context, event }) =>
			("socket" in event && context.socket === event.socket) || false,
	},
	actions: {
		warnUnavailableToken: () => warn("socket token unavailable", undefined),
		warnTokenTimeout: () => warn("socket token fetch timed out", undefined),
		warnTokenFailure: ({ event }) => {
			if (event.type === "xstate.error.actor.fetchSocketToken") {
				warn("socket token fetch threw", event.error);
			}
		},
		warnConnectionFailure: ({ event }) => {
			if (event.type === "CONNECTION_FAILED") {
				warn("realtime connection failed", event.cause);
			}
		},
		invalidate: ({ context }) => {
			try {
				context.invalidate();
			} catch (error) {
				warn("invalidation callback threw", error);
			}
		},
		resetBackoff: assign({ attemptsSinceJoin: 0 }),
		countRetry: assign(({ context }) => ({
			attemptsSinceJoin: context.attemptsSinceJoin + 1,
		})),
		constructSocket: assign(({ context, event, self }) => {
			if (
				event.type !== "xstate.done.actor.fetchSocketToken" ||
				!event.output ||
				event.output === socketSessionUnauthorized
			) {
				return {};
			}

			let socket: RealtimeSocket;
			try {
				socket = context.createSocket(context.socketUrl, {
					authToken: event.output,
					reconnectAfterMs: () => NEVER_MS,
				});
			} catch (error) {
				self.send({ type: "CONNECTION_FAILED", cause: error });
				return {};
			}

			const retired = () => {
				const snapshot = self.getSnapshot();
				return (
					snapshot.status !== "active" || snapshot.context.socket !== socket
				);
			};
			const lost = (reason?: string) => {
				if (retired()) {
					disconnect(socket, "retired socket disconnect threw");
					return;
				}
				warn("socket lost", reason);
				self.send({ type: "SOCKET_LOST", socket, reason });
			};

			try {
				socket.onError(lost);
				socket.onClose(() => lost());
				socket.onOpen(() => {
					if (retired()) disconnect(socket, "retired socket disconnect threw");
				});
			} catch (error) {
				warn("socket lifecycle wiring failed", error);
			}
			try {
				const channel = socket.channel("notifications:self");
				channel.on(NOTIFICATION_CREATED_EVENT, () => {
					const snapshot = self.getSnapshot();
					if (
						snapshot.status === "active" &&
						snapshot.context.socket === socket
					) {
						self.send({ type: "NOTIFICATION_CREATED", socket });
					}
				});
				return { socket, channel };
			} catch (error) {
				self.send({ type: "CONNECTION_FAILED", cause: error });
				disconnect(socket, "socket disconnect threw");
				return { socket: null, channel: null };
			}
		}),
		connectAndJoin: ({ context, self }) => {
			if (!context.socket || !context.channel) return;
			try {
				context.socket.connect();
				context.channel
					.join()
					.receive("ok", () =>
						self.send({ type: "CHANNEL_JOINED", socket: context.socket! }),
					)
					.receive("error", (reason) => warn("channel join rejected", reason))
					.receive("timeout", () => warn("channel join timed out", undefined));
			} catch (error) {
				self.send({ type: "CONNECTION_FAILED", cause: error });
			}
		},
		retireCurrent: assign(({ context }) => {
			if (context.channel) leave(context.channel);
			if (context.socket) disconnect(context.socket, "socket disconnect threw");
			return { socket: null, channel: null };
		}),
		retireStaleSocket: ({ event }) => {
			if (event.type === "SOCKET_LOST") {
				disconnect(event.socket, "retired socket disconnect threw");
			}
		},
	},
}).createMachine({
	id: "notificationRealtime",
	context: ({ input }) => ({
		...input,
		socket: null,
		channel: null,
		attemptsSinceJoin: 0,
	}),
	initial: "fetchingToken",
	states: {
		fetchingToken: {
			invoke: {
				id: "fetchSocketToken",
				src: "fetchSocketToken",
				input: ({ context }) => context.getSocketToken,
				onDone: [
					{ guard: "isUnauthorized", target: "stopped" },
					{
						guard: "hasToken",
						target: "connected",
						actions: "constructSocket",
					},
					{ target: "backingOff", actions: "warnUnavailableToken" },
				],
				onError: { target: "backingOff", actions: "warnTokenFailure" },
			},
			after: {
				[TOKEN_FETCH_TIMEOUT_MS]: {
					target: "backingOff",
					actions: "warnTokenTimeout",
				},
			},
		},
		connected: {
			entry: "connectAndJoin",
			on: {
				SOCKET_LOST: [
					{
						guard: "isCurrentSocket",
						target: "backingOff",
						actions: "retireCurrent",
					},
					{ actions: "retireStaleSocket" },
				],
				CONNECTION_FAILED: {
					target: "backingOff",
					actions: ["warnConnectionFailure", "retireCurrent"],
				},
				CHANNEL_JOINED: {
					guard: "isCurrentSocket",
					actions: ["resetBackoff", "invalidate"],
				},
				NOTIFICATION_CREATED: {
					guard: "isCurrentSocket",
					actions: "invalidate",
				},
			},
		},
		backingOff: {
			after: { backoff: { target: "fetchingToken", actions: "countRetry" } },
		},
		stopped: { type: "final", entry: "retireCurrent" },
	},
	on: { DESTROY: { target: ".stopped" } },
});

/**
 * Connect a Phoenix Socket and join the user's notification topic. The returned
 * handle is unchanged; only its implementation is now a per-handle XState actor.
 */
export function connectNotificationRealtime(
	config: NotificationRealtimeConfig,
): NotificationRealtimeHandle {
	const actor = createActor(notificationRealtimeMachine, {
		input: {
			socketUrl: config.socketUrl,
			getSocketToken: config.getSocketToken ?? defaultGetSocketToken,
			invalidate: config.invalidate,
			createSocket: config.createSocket ?? defaultCreateSocket,
		},
	});
	actor.start();
	return {
		destroy: () => {
			if (actor.getSnapshot().status !== "active") return;
			actor.send({ type: "DESTROY" });
			actor.stop();
		},
	};
}
