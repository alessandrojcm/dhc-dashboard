// Ambient type declarations for the official `phoenix` JavaScript client (v1.8).
// The package ships no TypeScript types; this declares only the surface that
// NotificationCenter uses: `Socket` (with `authToken`), `Channel`, and the
// `Push` returned by `channel.join()` and `channel.push()`.
// See https://hexdocs.pm/phoenix/1.8.7/js/index.html

declare module "phoenix" {
	export type PhoenixPayload = unknown;

	export interface PhoenixSocketOptions {
		/** Phoenix 1.8 native transport auth token (string or closure). */
		authToken?: string | (() => string);
		timeout?: number;
		heartbeatIntervalMs?: number;
		reconnectAfterMs?: (tries: number) => number;
		rejoinAfterMs?: (tries: number) => number;
		logger?: (kind: string, msg: string, data?: PhoenixPayload) => void;
		debug?: boolean;
		params?: Record<string, unknown>;
		vsn?: string;
	}

	export interface PhoenixChannelOptions {
		channel?: Channel;
		events?: { state: string; diff: string };
	}

	export class Push {
		receive(status: string, callback: (response: PhoenixPayload) => void): this;
		send(timeout?: number): this;
	}

	export class Channel {
		readonly topic: string;
		constructor(
			topic: string,
			params?: Record<string, unknown>,
			socket?: Socket,
		);
		join(timeout?: number): Push;
		leave(timeout?: number): Push;
		push(
			event: string,
			payload?: Record<string, unknown>,
			timeout?: number,
		): Push;
		on(
			event: string,
			callback: (payload: PhoenixPayload, ref?: string) => void,
		): string;
		off(event: string, ref?: string): void;
		onClose(callback: (payload?: PhoenixPayload) => void): string;
		onError(callback: (reason?: unknown) => void): string;
	}

	export class Socket {
		constructor(endPoint: string, opts?: PhoenixSocketOptions);
		connect(): void;
		disconnect(callback?: () => void, code?: number, reason?: string): void;
		channel(topic: string, params?: Record<string, unknown>): Channel;
		remove(channel: Channel): void;
		onOpen(callback: () => void): string;
		onClose(callback: () => void): string;
		onError(callback: (reason?: unknown) => void): string;
		onMessage(
			callback: (
				event: string,
				payload: PhoenixPayload,
				ref?: string,
			) => PhoenixPayload,
		): string;
		connectionState(): string;
		isConnected(): boolean;
	}

	export class LongPoll {
		constructor(endPoint: string);
	}

	export class Presence {
		constructor(channel: Channel, opts?: PhoenixChannelOptions);
	}

	export const Serializer: unknown;
}
