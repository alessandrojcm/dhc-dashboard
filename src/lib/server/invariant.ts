import { error } from "@sveltejs/kit";

function invariant(condition: unknown, message: string, errorCode?: number): asserts condition {
	if (condition) {
		error(errorCode ?? 404, { message });
	}
}

export { invariant };
