import { describe, expect, it } from "vitest";
import { decideLoanDrop, loanQueueDropHint } from "./loan-queue-dnd";

describe("decideLoanDrop", () => {
	it("opens approval for requested → handovers", () => {
		expect(
			decideLoanDrop({ fromStatus: "requested", toColumn: "handovers" }),
		).toEqual({
			kind: "openAction",
			action: "approve",
			readyForCheckout: undefined,
		});
	});

	it("opens checkout for approved → returns, forwarding readiness", () => {
		expect(
			decideLoanDrop({
				fromStatus: "approved",
				toColumn: "returns",
				readyForCheckout: false,
			}),
		).toEqual({
			kind: "openAction",
			action: "checkout",
			readyForCheckout: false,
		});
	});

	it("ignores same-column drops (order is server-owned)", () => {
		expect(
			decideLoanDrop({ fromStatus: "requested", toColumn: "requests" }),
		).toEqual({
			kind: "ignored",
			reason: "sameColumn",
		});
		expect(
			decideLoanDrop({ fromStatus: "approved", toColumn: "handovers" }),
		).toEqual({
			kind: "ignored",
			reason: "sameColumn",
		});
		expect(
			decideLoanDrop({ fromStatus: "checked_out", toColumn: "returns" }),
		).toEqual({ kind: "ignored", reason: "sameColumn" });
	});

	it("refuses maintenance targets (items, not loans)", () => {
		const outcome = decideLoanDrop({
			fromStatus: "requested",
			toColumn: "maintenance",
		});
		expect(outcome.kind).toBe("rejected");
	});

	it("refuses backwards moves with an explanatory reason", () => {
		const back = decideLoanDrop({
			fromStatus: "approved",
			toColumn: "requests",
		});
		expect(back.kind).toBe("rejected");
		if (back.kind === "rejected")
			expect(back.reason).toMatch(/back to Requests/);

		const skip = decideLoanDrop({
			fromStatus: "requested",
			toColumn: "returns",
		});
		expect(skip.kind).toBe("rejected");
		if (skip.kind === "rejected") expect(skip.reason).toMatch(/approval/);
	});

	it("refuses checked_out moves (return stays on the button)", () => {
		const outcome = decideLoanDrop({
			fromStatus: "checked_out",
			toColumn: "handovers",
		});
		expect(outcome.kind).toBe("rejected");
		if (outcome.kind === "rejected")
			expect(outcome.reason).toMatch(/Record return/);
	});

	it("has a hint for every outcome kind", () => {
		expect(Object.keys(loanQueueDropHint).sort()).toEqual(
			["ignored", "openAction", "rejected"].sort(),
		);
	});
});
