import { afterEach, describe, expect, it, vi } from "vitest";
import {
	connectNotificationRealtime,
	type RealtimeChannel,
	type RealtimePush,
	type RealtimeSocket,
	type SocketFactory,
} from "./notification-realtime.svelte";
import type { PhoenixPayload } from "phoenix";

/**
 * Focused NotificationCenter realtime bridge tests (ALE-164).
 *
 * The bridge now fetches a short-lived Phoenix socket token via a
 * `getSocketToken` callback (the browser exchanges the `_dhc_session` cookie
 * for it at `GET /api/auth/socket-token`) and passes it as `authToken` to the
 * Phoenix JS `Socket`. There is no Supabase client in the bridge anymore.
 *
 * Covered:
 *   1. socket token supplied as authToken + `notifications:self` topic joined;
 *   2. notification_created invalidates the exact query key;
 *   3. successful initial join and rejoin invalidate the same key;
 *   4. socket error/close reconnects with a fresh token, with bounded backoff,
 *      suppressing stale token fetches and replacing the dead socket;
 *   5. SIGNED_OUT-equivalent (destroy) leaves/disconnects without breaking HTTP;
 *   6. connection/join errors stay silent and never block invalidation calls;
 *   7. a failed, empty, or hung token fetch creates no socket and is retried
 *      with backoff; a late token from a superseded attempt is dropped;
 *   8. a retired socket that reconnects on its own is disconnected again.
 *
 * The Phoenix client boundary is substituted with an in-memory fake so no
 * WebSocket globals or network are involved. Full browser E2E is out of scope.
 */

type PushReceiver = {
	status: string;
	cb: (response: PhoenixPayload) => void;
}[];

interface FakeChannel extends RealtimeChannel {
	topic: string;
	receivers: PushReceiver;
	onCallbacks: Map<string, ((payload: PhoenixPayload) => void)[]>;
	leaveMock: ReturnType<typeof vi.fn>;
}

interface FakeSocket extends RealtimeSocket {
	url: string;
	authToken: string;
	connected: boolean;
	disconnected: boolean;
	channels: FakeChannel[];
	disconnectCount: number;
	reconnectAfterMs: (tries: number) => number;
	onErrorCb?: (reason?: string) => void;
	onCloseCb?: () => void;
	onOpenCb?: () => void;
}

function makeFakeChannel(topic: string): FakeChannel {
	const receivers: PushReceiver = [];
	const onCallbacks = new Map<string, ((payload: PhoenixPayload) => void)[]>();
	const leaveMock = vi.fn();

	const push = (): RealtimePush => {
		const api: RealtimePush = {
			receive(status: string, cb: (response: PhoenixPayload) => void) {
				receivers.push({ status, cb });
				return api;
			},
			send() {
				return api;
			},
		};
		return api;
	};

	const channel: FakeChannel = {
		topic,
		receivers,
		onCallbacks,
		leaveMock,
		join: vi.fn(() => push()),
		leave: vi.fn(() => {
			leaveMock();
			return push();
		}),
		on: vi.fn((event: string, cb: (payload: PhoenixPayload) => void) => {
			const list = onCallbacks.get(event) ?? [];
			list.push(cb);
			onCallbacks.set(event, list);
			return event;
		}),
	};
	return channel;
}

function makeFakeSocket(
	url: string,
	options: Parameters<SocketFactory>[1],
): FakeSocket {
	const { authToken, reconnectAfterMs } = options;
	const channels: FakeChannel[] = [];
	const socket: FakeSocket = {
		url,
		authToken,
		connected: false,
		disconnected: false,
		disconnectCount: 0,
		reconnectAfterMs,
		channels,
		connect: vi.fn(function (this: FakeSocket) {
			this.connected = true;
		}),
		disconnect: vi.fn(function (this: FakeSocket) {
			this.disconnected = true;
			this.connected = false;
			this.disconnectCount += 1;
		}),
		channel: vi.fn((topic: string) => {
			const ch = makeFakeChannel(topic);
			channels.push(ch);
			return ch;
		}),
		onError: vi.fn((cb: (reason?: string) => void) => {
			socket.onErrorCb = cb;
			return "error";
		}),
		onClose: vi.fn((cb: () => void) => {
			socket.onCloseCb = cb;
			return "close";
		}),
		onOpen: vi.fn((cb: () => void) => {
			socket.onOpenCb = cb;
			return "open";
		}),
	};
	return socket;
}

function emitChannelEvent(
	channel: FakeChannel,
	event: string,
	payload: PhoenixPayload = {},
) {
	for (const cb of channel.onCallbacks.get(event) ?? []) {
		cb(payload);
	}
}

function resolveJoin(
	channel: FakeChannel,
	status: string,
	response: PhoenixPayload = {},
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
	getSocketToken,
	createSocket,
}: {
	getSocketToken: () => Promise<string | null>;
	createSocket: SocketFactory;
}) {
	const invalidate = vi.fn();
	const handle = connectNotificationRealtime({
		socketUrl: SOCKET_URL,
		getSocketToken,
		invalidate,
		createSocket,
	});
	return { invalidate, handle };
}

let createdSockets: FakeSocket[] = [];
const createSocketFactory = (): SocketFactory => {
	createdSockets = [];
	return (url, options) => {
		const socket = makeFakeSocket(url, options);
		createdSockets.push(socket);
		return socket;
	};
};

// Upper bound on a single reconnect delay; waiting this long must always be
// enough for the next attempt to start.
const RECONNECT_CEILING_MS = 30_000;

/** Advance fake time in small steps until `done()` holds (bounded). */
async function advanceUntil(
	done: () => boolean,
	maxMs = 2 * RECONNECT_CEILING_MS,
) {
	for (let elapsed = 0; !done() && elapsed < maxMs; elapsed += 100) {
		await vi.advanceTimersByTimeAsync(100);
	}
	expect(done()).toBe(true);
}

afterEach(() => {
	createdSockets = [];
	vi.useRealTimers();
	vi.restoreAllMocks();
});

describe("connectNotificationRealtime (ALE-164 socket-token path)", () => {
	it("fetches a socket token, supplies it as authToken, and joins notifications:self", async () => {
		const createSocket = createSocketFactory();
		const { handle } = setup({
			getSocketToken: async () => "socket-token-A",
			createSocket,
		});
		await flush();

		expect(createdSockets).toHaveLength(1);
		expect(createdSockets[0].url).toBe(SOCKET_URL);
		expect(createdSockets[0].authToken).toBe("socket-token-A");
		expect(createdSockets[0].connect).toHaveBeenCalledTimes(1);
		expect(createdSockets[0].channels).toHaveLength(1);
		// ALE-164: the browser cannot read its own id from the opaque token, so
		// it joins the `notifications:self` alias.
		expect(createdSockets[0].channels[0].topic).toBe("notifications:self");

		handle.destroy();
	});

	it("invalidates the notifications query key when notification_created arrives", async () => {
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			getSocketToken: async () => "socket-token-A",
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
			getSocketToken: async () => "socket-token-A",
			createSocket,
		});
		await flush();

		invalidate.mockClear();
		const channel = createdSockets[0].channels[0];
		resolveJoin(channel, "ok", {});
		expect(invalidate).toHaveBeenCalledTimes(1);

		handle.destroy();
	});

	it("reconnects with a fresh socket token when the live socket errors", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		let tokenFetchCount = 0;
		const getSocketToken = vi.fn(async () => {
			tokenFetchCount += 1;
			return `socket-token-${tokenFetchCount}`;
		});
		const { invalidate, handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);
		resolveJoin(createdSockets[0].channels[0], "ok");
		expect(createdSockets[0].authToken).toBe("socket-token-1");

		createdSockets[0].onErrorCb?.("connection refused");
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(getSocketToken).toHaveBeenCalledTimes(2);
		expect(createdSockets).toHaveLength(2);
		expect(createdSockets[1].authToken).toBe("socket-token-2");
		expect(createdSockets[1].connected).toBe(true);
		expect(createdSockets[1].channels[0].topic).toBe("notifications:self");

		invalidate.mockClear();
		resolveJoin(createdSockets[1].channels[0], "ok");
		expect(invalidate).toHaveBeenCalledTimes(1);

		handle.destroy();
	});

	it("disconnects the old socket and leaves its channel when replacing it", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		const { handle } = setup({
			getSocketToken: async () => "socket-token-A",
			createSocket,
		});
		await vi.advanceTimersByTimeAsync(0);
		const oldSocket = createdSockets[0];

		oldSocket.onCloseCb?.();
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(oldSocket.disconnected).toBe(true);
		expect(oldSocket.channels[0].leaveMock).toHaveBeenCalled();
		expect(createdSockets).toHaveLength(2);
		expect(createdSockets[1].disconnected).toBe(false);

		handle.destroy();
	});

	it("ignores late errors from a socket it already replaced", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		const getSocketToken = vi.fn(async () => "socket-token-A");
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);
		const oldSocket = createdSockets[0];

		oldSocket.onErrorCb?.("boom");
		oldSocket.onCloseCb?.();
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);
		expect(createdSockets).toHaveLength(2);

		oldSocket.onErrorCb?.("late");
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(getSocketToken).toHaveBeenCalledTimes(2);
		expect(createdSockets).toHaveLength(2);

		handle.destroy();
	});

	it("creates no socket when destroyed during a pending token fetch", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		let resolveToken: (token: string) => void = () => {};
		const { handle } = setup({
			getSocketToken: () =>
				new Promise<string>((resolve) => {
					resolveToken = resolve;
				}),
			createSocket,
		});

		handle.destroy();
		resolveToken("socket-token-late");
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(createdSockets).toHaveLength(0);
	});

	it("drops a token that resolves after destroy during a reconnect", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		let calls = 0;
		let resolveSecond: (token: string) => void = () => {};
		const { handle } = setup({
			getSocketToken: () => {
				calls += 1;
				if (calls === 1) return Promise.resolve("socket-token-1");
				return new Promise<string>((resolve) => {
					resolveSecond = resolve;
				});
			},
			createSocket,
		});
		await vi.advanceTimersByTimeAsync(0);

		createdSockets[0].onErrorCb?.("boom");
		await advanceUntil(() => calls === 2);

		handle.destroy();
		resolveSecond("socket-token-2");
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(createdSockets).toHaveLength(1);
	});

	it("backs off between repeated failed attempts instead of looping tightly", async () => {
		vi.useFakeTimers();
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const getSocketToken = vi.fn(async () => null);
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);
		expect(getSocketToken).toHaveBeenCalledTimes(1);

		// Without backoff a failing endpoint would be hit continuously.
		await vi.advanceTimersByTimeAsync(500);
		expect(getSocketToken).toHaveBeenCalledTimes(1);

		// Over two minutes, attempts stay bounded and the gaps grow.
		await vi.advanceTimersByTimeAsync(120_000);
		const attempts = getSocketToken.mock.calls.length;
		expect(attempts).toBeGreaterThan(2);
		expect(attempts).toBeLessThan(15);
		expect(createdSockets).toHaveLength(0);

		handle.destroy();
		await vi.advanceTimersByTimeAsync(120_000);
		expect(getSocketToken).toHaveBeenCalledTimes(attempts);
	});

	it("keeps retrying after the live socket keeps failing, at the bounded ceiling", async () => {
		vi.useFakeTimers();
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const getSocketToken = vi.fn(async () => "socket-token-A");
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);

		for (let i = 0; i < 10; i += 1) {
			createdSockets.at(-1)?.onErrorCb?.("down");
			await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);
		}

		expect(createdSockets).toHaveLength(11);

		handle.destroy();
	});

	it("destroy tears down channel and disconnects without breaking HTTP", async () => {
		const createSocket = createSocketFactory();
		const { handle } = setup({
			getSocketToken: async () => "socket-token-A",
			createSocket,
		});
		await flush();

		const socket = createdSockets[0];
		const channel = socket.channels[0];
		handle.destroy();

		expect(channel.leaveMock).toHaveBeenCalled();
		expect(socket.disconnected).toBe(true);
	});

	it("connection/join errors stay silent and never block invalidation calls", async () => {
		const createSocket = createSocketFactory();
		const { invalidate, handle } = setup({
			getSocketToken: async () => "socket-token-A",
			createSocket,
		});
		await flush();

		// Simulate a channel join rejection.
		invalidate.mockClear();
		const channel = createdSockets[0].channels[0];
		resolveJoin(channel, "error", { reason: "unauthorized" });
		// No invalidation on error — only on `ok` and `notification_created`.
		expect(invalidate).not.toHaveBeenCalled();

		handle.destroy();
	});

	it("an empty token creates no socket and is retried after a backoff", async () => {
		vi.useFakeTimers();
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const getSocketToken = vi
			.fn<() => Promise<string | null>>()
			.mockResolvedValueOnce(null)
			.mockResolvedValue("socket-token-B");
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);

		expect(createdSockets).toHaveLength(0);
		expect(getSocketToken).toHaveBeenCalledTimes(1);

		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(getSocketToken).toHaveBeenCalledTimes(2);
		expect(createdSockets).toHaveLength(1);
		expect(createdSockets[0].authToken).toBe("socket-token-B");

		handle.destroy();
	});

	it("a throwing token fetch is swallowed and retried after a backoff", async () => {
		vi.useFakeTimers();
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const getSocketToken = vi
			.fn<() => Promise<string | null>>()
			.mockRejectedValueOnce(new Error("network down"))
			.mockResolvedValue("socket-token-B");
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);

		expect(createdSockets).toHaveLength(0);

		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(getSocketToken).toHaveBeenCalledTimes(2);
		expect(createdSockets).toHaveLength(1);
		expect(createdSockets[0].authToken).toBe("socket-token-B");

		handle.destroy();
	});

	it("drops a token that resolves after a newer attempt has started", async () => {
		vi.useFakeTimers();
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const resolvers: ((token: string) => void)[] = [];
		const getSocketToken = vi.fn(
			() =>
				new Promise<string>((resolve) => {
					resolvers.push(resolve);
				}),
		);
		const { handle } = setup({ getSocketToken, createSocket });

		// The first fetch hangs; the bridge gives up on it and starts a new one.
		await advanceUntil(() => resolvers.length === 2);

		resolvers[1]("socket-token-new");
		await vi.advanceTimersByTimeAsync(0);
		resolvers[0]("socket-token-stale");
		await vi.advanceTimersByTimeAsync(0);

		expect(createdSockets).toHaveLength(1);
		expect(createdSockets[0].authToken).toBe("socket-token-new");

		handle.destroy();
	});

	it("constructs sockets whose own reconnect loop never fires in practice", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		const { handle } = setup({
			getSocketToken: async () => "socket-token-A",
			createSocket,
		});
		await vi.advanceTimersByTimeAsync(0);

		const { reconnectAfterMs } = createdSockets[0];
		for (const tries of [1, 2, 10, 100]) {
			const delay = reconnectAfterMs(tries);
			// Finite and within setTimeout's range: larger values (or Infinity)
			// overflow and fire immediately.
			expect(delay).toBeLessThanOrEqual(2_147_483_647);
			expect(delay).toBeGreaterThanOrEqual(7 * 24 * 60 * 60 * 1000);
		}

		handle.destroy();
	});

	it("disconnects a replaced socket again if it reconnects on its own", async () => {
		vi.useFakeTimers();
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const createSocket = createSocketFactory();
		const getSocketToken = vi.fn(async () => "socket-token-A");
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);
		const oldSocket = createdSockets[0];

		oldSocket.onCloseCb?.();
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);
		expect(createdSockets).toHaveLength(2);
		const disconnectsAfterReplace = oldSocket.disconnectCount;

		// Phoenix's heartbeat-timeout teardown can still schedule its own
		// reconnect on the retired socket; it opens, then fails again.
		oldSocket.onOpenCb?.();
		expect(oldSocket.disconnectCount).toBe(disconnectsAfterReplace + 1);
		oldSocket.onErrorCb?.("expired token");
		oldSocket.onCloseCb?.();
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(oldSocket.disconnectCount).toBeGreaterThan(
			disconnectsAfterReplace + 1,
		);
		expect(getSocketToken).toHaveBeenCalledTimes(2);
		expect(createdSockets).toHaveLength(2);
		expect(createdSockets[1].disconnected).toBe(false);

		handle.destroy();
	});

	it("disconnects a destroyed bridge's socket again if it reconnects on its own", async () => {
		vi.useFakeTimers();
		const createSocket = createSocketFactory();
		const getSocketToken = vi.fn(async () => "socket-token-A");
		const { handle } = setup({ getSocketToken, createSocket });
		await vi.advanceTimersByTimeAsync(0);
		const socket = createdSockets[0];

		handle.destroy();
		const disconnectsAfterDestroy = socket.disconnectCount;
		socket.onOpenCb?.();
		await vi.advanceTimersByTimeAsync(RECONNECT_CEILING_MS);

		expect(socket.disconnectCount).toBe(disconnectsAfterDestroy + 1);
		expect(getSocketToken).toHaveBeenCalledTimes(1);
	});
});
