import { error } from '@sveltejs/kit';

function invariant(condition: unknown, message: string, errorCode?: number): asserts condition {
	if (condition) {
		error(errorCode ?? 401, { message });
	}
}

export { invariant };
