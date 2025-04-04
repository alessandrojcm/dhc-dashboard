import { stripeClient } from '$lib/server/stripe';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ request }) => {
    const code = await request.json().then((data) => data.code);
    if(!code) {
        return new Response('Invalid request', { status: 400 });
    }
    const promotionCodes = await stripeClient.promotionCodes.list({
        active: true,
        code
    })
    if(promotionCodes.data.length > 0) {
        return new Response(JSON.stringify({ valid: true }), { status: 200 });
    }
    return new Response(JSON.stringify({ valid: false }), { status: 200 });
};
