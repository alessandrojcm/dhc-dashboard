import { error } from "@sveltejs/kit";

function invariant(condition: unknown, message: string): asserts condition {
	if (condition) {
		error(404, { message });
	}
}

export { invariant };
