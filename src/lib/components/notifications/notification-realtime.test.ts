import { afterEach, describe, expect, it, vi } from "vitest";
import {
	connectNotificationRealtime,
	type SocketFactory,
} from "./notification-realtime.svelte";
import type { Channel, Push, Socket } from "phoenix";

/**
 * Focused NotificationCenter realtime bridge tests.
 *
 * These cover the component/client seams required by ALE-143 and the secure
 * browser integration spec:
 *   1. current token supplied as authToken + own user topic joined;
 *   2. notification_created invalidates the exact query key;
 *   3. successful initial join and rejoin invalidate the same key;
 *   4. TOKEN_REFRESHED replaces the connection with the new token;
 *   5. SIGNED_OUT and component cleanup leave/disconnect without breaking HTTP;
 *   6. connection/join errors stay silent and never block invalidation calls.
 *
 * The Phoenix client boundary is substituted with an in-memory fake so no
 * WebSocket globals or network are involved. Full browser E2E is out of scope.
 */

type PushReceiver = {
	status: string;
	cb: (response: unknown) => void;
}[];

interface FakeChannel extends Channel {
	topic: string;
	receivers: PushReceiver;
	onCallbacks: Map<string, ((payload: unknown) => void)[]>;
	leaveMock: ReturnType<typeof vi.fn>;
}

interface FakeSocket extends Socket {
	url: string;
	authToken: string;
	connected: boolean;
	disconnected: boolean;
	channels: FakeChannel[];
	onErrorCb?: (reason?: unknown) => void;
}

function makeFakeChannel(topic: string): FakeChannel {
	const receivers: PushReceiver = [];
	const onCallbacks = new Map<string, ((payload: unknown) => void)[]>();
	const leaveMock = vi.fn();

	const push = (): Push => {
		const api = {
			receive(status: string, cb: (response: unknown) => void) {
				receivers.push({ status, cb });
				return api;
			},
			send() {
				return api;
			},
		} as unknown as Push;
		return api;
	};

	return {
		topic,
		receivers,
		onCallbacks,
		leaveMock,
		join: vi.fn(() => push()),
		leave: vi.fn((() => {
			leaveMock();
			return push();
		}) as () => Push),
		push: vi.fn(() => push()),
		on: vi.fn((event: string, cb: (payload: unknown) => void) => {
			const list = onCallbacks.get(event) ?? [];
			list.push(cb);
			onCallbacks.set(event, list);
			return event;
		}),
		off: vi.fn(),
		onClose: vi.fn(),
		onError: vi.fn(),
	} as unknown as FakeChannel;
}

function makeFakeSocket(url: string, authToken: string): FakeSocket {
	const channels: FakeChannel[] = [];
	return {
		url,
		authToken,
		connected: false,
		disconnected: false,
		channels,
		connect: vi.fn(function (this: FakeSocket) {
			this.connected = true;
		}),
		disconnect: vi.fn(function (this: FakeSocket) {
			this.disconnected = true;
			this.connected = false;
		}),
		channel: vi.fn((topic: string) => {
			const ch = makeFakeChannel(topic);
			channels.push(ch);
			return ch;
		}),
		remove: vi.fn(),
		onOpen: vi.fn(),
		onClose: vi.fn(),
		onError: vi.fn(function (this: FakeSocket, cb: (r?: unknown) => void) {
			this.onErrorCb = cb;
		}),
		onMessage: vi.fn(),
		connectionState: vi.fn(() => "open"),
		isConnected: vi.fn(),
	} as unknown as FakeSocket;
}

interface FakeSupabaseAuth {
	getSession: ReturnType<typeof vi.fn>;
	onAuthStateChange: ReturnType<typeof vi.fn>;
}

interface FakeSupabase {
	auth: FakeSupabaseAuth;
}

function makeFakeSupabase(session: {
	access_token: string;
	user: { id: string };
}): FakeSupabase {
	return {
		auth: {
			getSession: vi.fn(async () => ({ data: { session }, error: null })),
			onAuthStateChange: vi.fn(
				(
					cb: (
						event: string,
						session: { access_token: string; user: { id: string } } | null,
					) => void,
				) => {
					// The callback is later invoked via `emitAuth`, which reads it
					// back from `onAuthStateChange.mock.calls`.
					void cb;
					return {
						data: {
							subscription: { unsubscribe: vi.fn() },
						},
					};
				},
			),
		},
	};
}

/** Emits an auth event to the most recently registered Supabase listener. */
function emitAuth(
	supabase: FakeSupabase,
	event: string,
	session: { access_token: string; user: { id: string } } | null,
) {
	// Reach into the mock to call the captured callback. onAuthStateChange is a
	// vi.fn; its last call's first argument is the callback.
	const calls = supabase.auth.onAuthStateChange.mock.calls;
	const cb = calls[calls.length - 1]?.[0] as
		| ((
				e: string,
				s: { access_token: string; user: { id: string } } | null,
		  ) => void)
		| undefined;
	cb?.(event, session);
}

function emitChannelEvent(
	channel: FakeChannel,
	event: string,
	payload: unknown = {},
) {
	for (const cb of channel.onCallbacks.get(event) ?? []) {
		cb(payload);
	}
}

function resolveJoin(
	channel: FakeChannel,
	status: string,
	response: unknown = {},
) {
	for (const r of channel.receivers) {
		if (r.status === status) r.cb(response);
	}
}

function flush() {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

const SOCKET_URL = "ws://localhost:4000/socket";

function setup({
	session,
	createSocket,
}: {
	session: { access_token: string; user: { id: string } };
	createSocket: SocketFactory;
}) {
	const invalidate = vi.fn();
	const supabase = makeFakeSupabase(session);
	const handle = connectNotificationRealtime({
		socketUrl: SOCKET_URL,
		supabase: supabase as unknown as Parameters<
			typeof connectNotificationRealtime
		>[0]["supabase"],
		invalidate,
		createSocket,
	});
	return { invalidate, supabase, handle };
}

let createdSockets: FakeSocket[] = [];
const createSocketFactory = (): SocketFactory => {
	createdSockets = [];
	return (url, options) => {
		const socket = makeFakeSocket(url, options.authToken);
		createdSockets.push(socket);
		return socket as unknown as Socket;
	};
};

afterEach(() => {
	createdSockets = [];
	vi.restoreAllMocks();
});

describe("connectNotificationRealtime", () => {
	it("supplies the current access token as authToken and joins the current user's notification topic", async () => {
		const createSocket = createSocketFactory();
		const { handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		expect(createdSockets).toHaveLength(1);
		expect(createdSockets[0].url).toBe(SOCKET_URL);
		expect(createdSockets[0].authToken).toBe("token-A");
		expect(createdSockets[0].connect).toHaveBeenCalledTimes(1);
		expect(createdSockets[0].channels).toHaveLength(1);
		expect(createdSockets[0].channels[0].topic).toBe("notifications:user-1");

		handle.destroy();
	});

	it("invalidates the notifications query key when notification_created arrives", async () => {
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const channel = createdSockets[0].channels[0];
		expect(channel.on).toHaveBeenCalledWith(
			"notification_created",
			expect.any(Function),
		);

		invalidate.mockClear();
		emitChannelEvent(channel, "notification_created", {});
		expect(invalidate).toHaveBeenCalledTimes(1);

		handle.destroy();
	});

	it("invalidates the same key after a successful initial join", async () => {
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const channel = createdSockets[0].channels[0];
		expect(channel.join).toHaveBeenCalledTimes(1);

		invalidate.mockClear();
		resolveJoin(channel, "ok");
		expect(invalidate).toHaveBeenCalledTimes(1);

		handle.destroy();
	});

	it("invalidates the same key after a successful rejoin (ok received again)", async () => {
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const channel = createdSockets[0].channels[0];

		// First join ok.
		resolveJoin(channel, "ok");
		// Simulate Phoenix rejoin after an error: a second "ok" arrives on the
		// same channel's join push receivers.
		invalidate.mockClear();
		resolveJoin(channel, "ok");
		expect(invalidate).toHaveBeenCalledTimes(1);

		handle.destroy();
	});

	it("replaces the connection with a new socket carrying the refreshed token on TOKEN_REFRESHED", async () => {
		const createSocket = createSocketFactory();
		const { supabase, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const firstSocket = createdSockets[0];
		expect(firstSocket.authToken).toBe("token-A");

		emitAuth(supabase, "TOKEN_REFRESHED", {
			access_token: "token-B",
			user: { id: "user-1" },
		});
		await flush();

		// Old socket/channel torn down and a new one built with token-B.
		expect(firstSocket.disconnect).toHaveBeenCalled();
		expect(createdSockets).toHaveLength(2);
		expect(createdSockets[1].authToken).toBe("token-B");
		expect(createdSockets[1].channels[0].topic).toBe("notifications:user-1");
		expect(firstSocket.channels[0].leaveMock).toHaveBeenCalled();

		handle.destroy();
	});

	it("leaves the channel and disconnects the socket on SIGNED_OUT", async () => {
		const createSocket = createSocketFactory();
		const { supabase, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const socket = createdSockets[0];
		const channel = socket.channels[0];
		const unsub =
			supabase.auth.onAuthStateChange.mock.results[0].value.data.subscription
				.unsubscribe;

		emitAuth(supabase, "SIGNED_OUT", null);
		await flush();

		expect(channel.leaveMock).toHaveBeenCalled();
		expect(socket.disconnect).toHaveBeenCalled();
		expect(unsub).toHaveBeenCalled();

		// Cleanup remains idempotent after SIGNED_OUT removed the listener.
		handle.destroy();
	});

	it("removes the auth listener, leaves the channel, and disconnects the socket on component cleanup", async () => {
		const createSocket = createSocketFactory();
		const { supabase, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const socket = createdSockets[0];
		const channel = socket.channels[0];
		const unsub =
			supabase.auth.onAuthStateChange.mock.results[0].value.data.subscription
				.unsubscribe;

		handle.destroy();

		expect(unsub).toHaveBeenCalled();
		expect(channel.leaveMock).toHaveBeenCalled();
		expect(socket.disconnect).toHaveBeenCalled();
	});

	it("stays silent on socket construction failure and never calls invalidate", async () => {
		const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket: SocketFactory = () => {
			throw new Error("boom");
		};
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		expect(invalidate).not.toHaveBeenCalled();
		expect(warnSpy).toHaveBeenCalled();

		// HTTP behavior is unaffected: destroy must still run cleanly.
		expect(() => handle.destroy()).not.toThrow();
		warnSpy.mockRestore();
	});

	it("stays silent when socket connect throws and remains safe to clean up", async () => {
		const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
		const socket = makeFakeSocket(SOCKET_URL, "token-A");
		socket.connect = vi.fn(() => {
			throw new Error("connect failed");
		});
		const createSocket: SocketFactory = () => socket as unknown as Socket;
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		expect(invalidate).not.toHaveBeenCalled();
		expect(warnSpy).toHaveBeenCalled();
		expect(() => handle.destroy()).not.toThrow();
		expect(socket.disconnect).toHaveBeenCalled();
		warnSpy.mockRestore();
	});

	it("stays silent on channel join rejection and preserves later invalidation", async () => {
		const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const channel = createdSockets[0].channels[0];
		invalidate.mockClear();
		resolveJoin(channel, "error", { reason: "unauthorized" });

		// Join error did not invalidate (only ok does).
		expect(invalidate).not.toHaveBeenCalled();
		expect(warnSpy).toHaveBeenCalled();

		// A subsequent notification_created event still invalidates: realtime
		// failure does not disable the query invalidation path.
		emitChannelEvent(channel, "notification_created", {});
		expect(invalidate).toHaveBeenCalledTimes(1);

		handle.destroy();
		warnSpy.mockRestore();
	});

	it("does not connect when there is no session (mirrors the component's missing-URL guard)", async () => {
		// The component skips mounting when env.PUBLIC_PHOENIX_SOCKET_URL is
		// empty. The bridge itself is not URL-aware, so this test documents the
		// contract by asserting a missing session does not connect either.
		const createSocket = createSocketFactory();
		const supabase: FakeSupabase = {
			auth: {
				getSession: vi.fn(async () => ({
					data: { session: null },
					error: null,
				})),
				onAuthStateChange: vi.fn(() => ({
					data: {
						subscription: { unsubscribe: vi.fn() },
					},
				})),
			},
		};
		const invalidate = vi.fn();
		const handle = connectNotificationRealtime({
			socketUrl: SOCKET_URL,
			supabase: supabase as unknown as Parameters<
				typeof connectNotificationRealtime
			>[0]["supabase"],
			invalidate,
			createSocket,
		});
		await flush();

		expect(createdSockets).toHaveLength(0);
		expect(invalidate).not.toHaveBeenCalled();
		handle.destroy();
	});

	it("treats duplicate notification_created signals as harmless repeated invalidations", async () => {
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			session: { access_token: "token-A", user: { id: "user-1" } },
			createSocket,
		});
		await flush();

		const channel = createdSockets[0].channels[0];
		invalidate.mockClear();
		emitChannelEvent(channel, "notification_created", {});
		emitChannelEvent(channel, "notification_created", {});
		// Duplicate signals => duplicate invalidations, which TanStack Query
		// deduplicates into one refetch. The contract is "harmless".
		expect(invalidate).toHaveBeenCalledTimes(2);

		handle.destroy();
	});
});
