import { createSeedClient } from '@snaplet/seed';

async function globalSetup() {
    await createSeedClient().then((d) => d.$resetDatabase());
}

export default globalSetup;