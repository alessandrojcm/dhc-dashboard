import { initialTransition, setup } from "xstate";

/**
 * Pure drop decision for the containers storage map.
 *
 * Maps one drag (the dragged container plus the drop target) onto an explicit
 * outcome. It runs through XState's pure `initialTransition` only: no actor
 * is ever created, so there is nothing to leak across components. Phoenix
 * (`Dhc.Inventory.Containers.move_container/2`) remains the only authority
 * on durable state; this machine decides *how the page reacts* to a drop.
 * A drop that the machine allows commits through the dedicated move
 * mutation; the backend re-checks cycles and archived parents under lock
 * (`:circular_parent`, `:archived_parent`), so a stale client view fails
 * with a domain toast instead of corrupt data.
 *
 * Deliberately refused:
 * - Onto itself or the same parent: there is nothing to move.
 * - Into one of its own descendants: that would be a cycle, and the backend
 *   refuses it as `:circular_parent`.
 * - Into an archived parent: the backend refuses it as `:archived_parent`;
 *   restore the parent chain first.
 * - Archived containers are not draggable at all: archive/restore owns them.
 */

export type ContainerSnapshot = {
	id: string;
	parentContainerId: string | null;
	archivedAt: string | null;
};

export type ContainerDropInput = {
	draggedId: string;
	/** `null` targets the Root drop zone (a top-level location). */
	targetId: string | null;
	containers: ContainerSnapshot[];
};

export type ContainerDropOutcome =
	| { kind: "move"; parentId: string | null }
	| { kind: "ignored"; reason: "ontoSelf" | "sameParent" }
	| { kind: "rejected"; reason: string };

type DropContext = {
	draggedId: string;
	targetId: string | null;
	containers: ContainerSnapshot[];
};

function byId(containers: ContainerSnapshot[], id: string) {
	return containers.find((container) => container.id === id);
}

/** Whether `ancestorId` is reachable from `childId` by walking parent links. */
function isDescendantOf(
	containers: ContainerSnapshot[],
	childId: string,
	ancestorId: string,
): boolean {
	let current = byId(containers, childId)?.parentContainerId ?? null;
	while (current) {
		if (current === ancestorId) return true;
		current = byId(containers, current)?.parentContainerId ?? null;
	}
	return false;
}

const containerDropMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as DropContext,
		input: {} as ContainerDropInput,
		output: {} as ContainerDropOutcome,
	},
	guards: {
		unknownDragged: ({ context }) =>
			!byId(context.containers, context.draggedId),
		ontoSelf: ({ context }) => context.targetId === context.draggedId,
		sameParent: ({ context }) => {
			const dragged = byId(context.containers, context.draggedId);
			return !!dragged && dragged.parentContainerId === context.targetId;
		},
		draggedArchived: ({ context }) =>
			byId(context.containers, context.draggedId)?.archivedAt != null,
		unknownTarget: ({ context }) =>
			context.targetId !== null && !byId(context.containers, context.targetId),
		targetArchived: ({ context }) =>
			context.targetId !== null &&
			byId(context.containers, context.targetId)?.archivedAt != null,
		circularMove: ({ context }) =>
			context.targetId !== null &&
			isDescendantOf(context.containers, context.targetId, context.draggedId),
	},
}).createMachine({
	id: "containerDrop",
	context: ({ input }) => ({
		draggedId: input.draggedId,
		targetId: input.targetId,
		containers: input.containers,
	}),
	initial: "evaluating",
	states: {
		evaluating: {
			always: [
				{ guard: "unknownDragged", target: "unknownRefused" },
				{ guard: "ontoSelf", target: "ontoSelf" },
				{ guard: "sameParent", target: "sameParent" },
				{ guard: "draggedArchived", target: "archivedDragged" },
				{ guard: "unknownTarget", target: "unknownRefused" },
				{ guard: "targetArchived", target: "archivedTarget" },
				{ guard: "circularMove", target: "circular" },
				{ target: "move" },
			],
		},
		move: {
			type: "final",
			output: ({ context }) => ({
				kind: "move" as const,
				parentId: context.targetId,
			}),
		},
		ontoSelf: {
			type: "final",
			output: () => ({ kind: "ignored" as const, reason: "ontoSelf" as const }),
		},
		sameParent: {
			type: "final",
			output: () => ({
				kind: "ignored" as const,
				reason: "sameParent" as const,
			}),
		},
		archivedDragged: {
			type: "final",
			output: () => ({
				kind: "rejected" as const,
				reason: "Archived locations move through restore, not drag.",
			}),
		},
		archivedTarget: {
			type: "final",
			output: () => ({
				kind: "rejected" as const,
				reason:
					"That location is archived: restore it before moving anything into it.",
			}),
		},
		circular: {
			type: "final",
			output: () => ({
				kind: "rejected" as const,
				reason:
					"A location cannot move into itself or one of its own children.",
			}),
		},
		unknownRefused: {
			type: "final",
			output: () => ({
				kind: "rejected" as const,
				reason: "That location is no longer on the map: refresh and try again.",
			}),
		},
	},
	// SAFETY: every final state above declares an `output` of type
	// `ContainerDropOutcome`; the root output only forwards the done-state event's.
	output: ({ event }) => event.output as ContainerDropOutcome,
});

/**
 * Decide how the page reacts to a drop. Pure: the same input always yields
 * the same outcome.
 */
export function decideContainerDrop(
	input: ContainerDropInput,
): ContainerDropOutcome {
	const [snapshot] = initialTransition(containerDropMachine, input);
	if (snapshot.status !== "done" || !snapshot.output) {
		throw new Error("containerDropMachine did not reach an outcome");
	}
	return snapshot.output;
}
