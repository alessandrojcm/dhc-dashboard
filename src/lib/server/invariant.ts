import { error } from "@sveltejs/kit";

function invariant(condition: boolean, message: string, errorCode?: number): asserts condition is false {
	if (condition) {
		error(errorCode ?? 401, { message });
	}
}

export { invariant };
