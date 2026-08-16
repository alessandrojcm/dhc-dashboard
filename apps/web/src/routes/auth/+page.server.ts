import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ cookies }) => {
	const prefillEmail = cookies.get("invitation-sign-in-prefill");
	if (prefillEmail) {
		cookies.delete("invitation-sign-in-prefill", { path: "/auth" });
	}

	return { prefillEmail };
};
