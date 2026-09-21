import { describe, expect, it } from "vitest";
import { decideContainerDrop, type ContainerSnapshot } from "./container-dnd";

const containers: ContainerSnapshot[] = [
	{ id: "room", parentContainerId: null, archivedAt: null },
	{ id: "cupboard", parentContainerId: "room", archivedAt: null },
	{ id: "crate", parentContainerId: "cupboard", archivedAt: null },
	{ id: "shelf", parentContainerId: "room", archivedAt: null },
	{ id: "old-box", parentContainerId: null, archivedAt: "2026-01-01" },
];

describe("decideContainerDrop", () => {
	it("moves a container into another container", () => {
		expect(
			decideContainerDrop({
				draggedId: "crate",
				targetId: "shelf",
				containers,
			}),
		).toEqual({ kind: "move", parentId: "shelf" });
	});

	it("moves a container to Root", () => {
		expect(
			decideContainerDrop({ draggedId: "crate", targetId: null, containers }),
		).toEqual({ kind: "move", parentId: null });
	});

	it("ignores drops onto itself or the same parent", () => {
		expect(
			decideContainerDrop({
				draggedId: "crate",
				targetId: "crate",
				containers,
			}),
		).toEqual({ kind: "ignored", reason: "ontoSelf" });
		expect(
			decideContainerDrop({
				draggedId: "crate",
				targetId: "cupboard",
				containers,
			}),
		).toEqual({ kind: "ignored", reason: "sameParent" });
	});

	it("refuses moves into its own descendants", () => {
		const outcome = decideContainerDrop({
			draggedId: "cupboard",
			targetId: "crate",
			containers,
		});
		expect(outcome.kind).toBe("rejected");
		if (outcome.kind === "rejected")
			expect(outcome.reason).toMatch(/own children/);
	});

	it("refuses moves into archived parents", () => {
		const outcome = decideContainerDrop({
			draggedId: "crate",
			targetId: "old-box",
			containers,
		});
		expect(outcome.kind).toBe("rejected");
		if (outcome.kind === "rejected") expect(outcome.reason).toMatch(/archived/);
	});

	it("refuses to drag archived containers", () => {
		const outcome = decideContainerDrop({
			draggedId: "old-box",
			targetId: "room",
			containers,
		});
		expect(outcome.kind).toBe("rejected");
		if (outcome.kind === "rejected") expect(outcome.reason).toMatch(/restore/);
	});

	it("refuses unknown ids (stale view)", () => {
		expect(
			decideContainerDrop({
				draggedId: "missing",
				targetId: "room",
				containers,
			}).kind,
		).toBe("rejected");
		expect(
			decideContainerDrop({
				draggedId: "crate",
				targetId: "missing",
				containers,
			}).kind,
		).toBe("rejected");
	});
});
