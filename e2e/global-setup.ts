import { createSeedClient } from "@snaplet/seed";

async function globalSetup() {
	const client = await createSeedClient();
	await client.$resetDatabase();
	await client.settings([
		{ key: "waitlist_open", value: "true", type: "boolean" },
		{ key: "hema_insurance_form_link", value: "", type: "text" },
	]);
}

export default globalSetup;
