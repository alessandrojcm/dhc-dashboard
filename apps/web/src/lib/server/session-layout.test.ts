import {
	afterAll,
	beforeAll,
	beforeEach,
	describe,
	expect,
	it,
	vi,
} from "vitest";
import { getClient } from "@dhc/api-client";
import { load } from "../../routes/+layout.server.js";
import type { LayoutServerLoad } from "../../routes/$types.js";

describe("root layout session reads", () => {
	const originalConfig = getClient().getConfig();
	const fetch = vi.fn<typeof globalThis.fetch>();
	beforeAll(() => getClient().setConfig({ retry: 0, kyOptions: { fetch } }));
	afterAll(() => getClient().setConfig(originalConfig));
	beforeEach(() => {
		fetch.mockReset();
		fetch.mockResolvedValue(
			Response.json({ errors: { detail: "Unauthorized" } }, { status: 401 }),
		);
	});

	function event(session: App.Locals["session"] | undefined) {
		const request: Partial<Parameters<LayoutServerLoad>[0]> = {
			locals: {
				session: session ?? null,
				safeGetSession: async () => ({ session: session ?? null }),
			},
			cookies: {
				get: () => "expired-cookie",
				getAll: () => [],
				set: vi.fn(),
				delete: vi.fn(),
				serialize: () => "",
				parse: () => ({ name: "_dhc_session", value: "expired-cookie" }),
			},
		};
		// Public routes skip authGuard, leaving the session local absent.
		if (session === undefined && request.locals)
			Reflect.deleteProperty(request.locals, "session");
		// SAFETY: this load uses only locals and cookies, supplied in full above.
		return request as Parameters<LayoutServerLoad>[0];
	}

	it("reuses a signed-out result already read by the auth hook", async () => {
		expect(await load(event(null))).toMatchObject({ session: null });
		expect(fetch).not.toHaveBeenCalled();
	});

	it("still reads the session for public routes where the hook did not run", async () => {
		expect(await load(event(undefined))).toMatchObject({ session: null });
		expect(fetch).toHaveBeenCalledTimes(1);
	});
});
