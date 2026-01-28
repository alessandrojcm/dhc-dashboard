import { getSupabaseServiceClient } from "./setupFunctions";

async function globalSetup() {
	const supabase = getSupabaseServiceClient();

	const { data: users } = await supabase.auth.admin.listUsers();
	for (const user of users?.users || []) {
		await supabase.auth.admin.deleteUser(user.id);
	}

	await supabase.from("settings").delete().neq("key", "");
	await supabase.from("settings").insert([
		{ key: "waitlist_open", value: "true", type: "boolean" },
		{ key: "hema_insurance_form_link", value: "", type: "text" },
	]);
}

export default globalSetup;
