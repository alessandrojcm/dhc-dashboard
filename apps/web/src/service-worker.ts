/// <reference no-default-lib="true" />
/// <reference lib="esnext" />
/// <reference lib="webworker" />
/// <reference types="@sveltejs/kit" />

// ALE-270: shell-caching service worker. Caches the app shell (build outputs +
// static files) keyed by the deployment version; navigation requests fall back
// to the cached shell when offline. API requests are never intercepted or
// cached — offline data is explicitly out of scope.
//
// ALE-299: also the Web Push receiver. A `push` event displays the persisted
// notification's body; a click focuses an open dashboard window (or opens
// one). The decisions live in `$lib/service-worker/push` so they are
// unit-tested; this file only wires the events.

import { build, files, version } from "$service-worker";
import * as v from "valibot";
import {
	DEFAULT_URL,
	parsePushPayload,
	resolveClickTarget,
	sameOriginPath,
} from "$lib/service-worker/push";

// `notification.data` round-trips through the browser's structured clone, so
// it is parsed again rather than trusted.
const notificationDataSchema = v.object({ url: v.string() });

// This file is only ever executed as a service worker, where the global scope
// is a `ServiceWorkerGlobalScope`; the push handlers below need its
// `registration` and `clients`. Declared rather than cast so no runtime code
// is emitted for it.
declare const self: ServiceWorkerGlobalScope;

// Create a unique cache name for this deployment
const CACHE = `cache-${version}`;

const ASSETS = [
	...build, // the app itself
	...files, // everything in `static`
];

self.addEventListener("install", (event) => {
	// Create a new cache and add all files to it
	async function addFilesToCache() {
		const cache = await caches.open(CACHE);
		await cache.addAll(ASSETS);
	}

	event.waitUntil(addFilesToCache());
});

self.addEventListener("activate", (event) => {
	// Remove previous cached data from disk
	async function deleteOldCaches() {
		for (const key of await caches.keys()) {
			if (key !== CACHE) await caches.delete(key);
		}
	}

	event.waitUntil(deleteOldCaches());
});

self.addEventListener("fetch", (event) => {
	// Only handle GET requests; never intercept API traffic.
	if (event.request.method !== "GET") return;
	const url = new URL(event.request.url);
	if (url.origin !== self.location.origin) return;
	if (url.pathname.startsWith("/api/")) return;

	async function respond() {
		const cache = await caches.open(CACHE);

		// `build`/`files` can always be served from the cache
		if (ASSETS.includes(url.pathname)) {
			const response = await cache.match(url.pathname);
			if (response) {
				return response;
			}
		}

		// for everything else, try the network first, but
		// fall back to the cache if we're offline
		try {
			const response = await fetch(event.request);

			// if we're offline, fetch can return a value that is not a Response
			// instead of throwing - and we can't pass this non-Response to respondWith
			if (!(response instanceof Response)) {
				throw new Error("invalid response from fetch");
			}

			if (
				response.status === 200 &&
				!response.headers.get("cache-control")?.includes("no-store")
			) {
				cache.put(event.request, response.clone());
			}

			return response;
		} catch (err) {
			// Navigation requests fall back to the cached shell so an offline
			// open of any route renders the app shell rather than a network error.
			if (event.request.mode === "navigate") {
				const shell = await cache.match("/");
				if (shell) {
					return shell;
				}
			}

			const response = await cache.match(event.request);
			if (response) {
				return response;
			}

			// if there's no cache, then just error out
			// as there is nothing we can do to respond to this request
			throw err;
		}
	}

	event.respondWith(respond());
});

self.addEventListener("push", (event) => {
	const display = parsePushPayload(event.data ? event.data.text() : null);

	event.waitUntil(
		self.registration.showNotification(display.title, {
			body: display.body,
			tag: display.tag,
			icon: "/icon-192.png",
			badge: "/icon-192.png",
			data: { url: display.url },
		}),
	);
});

self.addEventListener("notificationclick", (event) => {
	event.notification.close();
	const data = v.safeParse(notificationDataSchema, event.notification.data);
	const path = data.success ? sameOriginPath(data.output.url) : DEFAULT_URL;

	async function openDashboard() {
		const windows = await self.clients.matchAll({
			type: "window",
			includeUncontrolled: true,
		});
		const target = resolveClickTarget(windows, self.location.origin, path);

		if (target.action === "focus") {
			const focused = await target.client.focus();
			// Navigating a focused client is best-effort: it can be refused for a
			// window the worker does not control, in which case focusing is still
			// the right outcome.
			if ("navigate" in focused && focused.url !== target.url) {
				await focused.navigate(target.url).catch(() => null);
			}
			return;
		}

		await self.clients.openWindow(target.url);
	}

	event.waitUntil(openDashboard());
});
