import { resetE2EState } from "./e2eApi";

async function globalSetup() {
	await resetE2EState();
}

export default globalSetup;
