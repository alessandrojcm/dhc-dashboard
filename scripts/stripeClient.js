import stripe from 'stripe';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

dotenv.config({ path: join(__dirname, '..', '.env') });

const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
if (!STRIPE_SECRET_KEY) {
	throw new Error('Missing STRIPE_SECRET_KEY in environment variables');
}

export const stripeClient = new stripe(STRIPE_SECRET_KEY, {
	apiVersion: '2024-12-18.acacia'
});
