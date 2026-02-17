import { exec } from "node:child_process";
import { promisify } from "node:util";
import { createSeedClient } from "@snaplet/seed";

const execAsync = promisify(exec);

async function globalSetup() {
	const client = await createSeedClient();
	await client.$resetDatabase();
	await client.settings([
		{ key: "waitlist_open", value: "true", type: "boolean" },
		{ key: "hema_insurance_form_link", value: "", type: "text" },
	]);

	// Seed test data for pagination tests
	console.log("Seeding test data...");
	await execAsync("node scripts/seedMembers.js 30");
	await execAsync("node scripts/seedWaitlist.js 30");
	console.log("Test data seeded successfully");
}

export default globalSetup;
