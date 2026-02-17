import {command, getRequestEvent, query} from "$app/server";
import {error} from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import * as v from 'valibot'
import {createPricingService} from "$lib/server/services/invitations";


const pricingSchema = v.object({
    code: v.optional(v.string()),
    invitationId: v.pipe(v.string(), v.uuid())
});

export const getPricingDetail = query(pricingSchema, async ({invitationId, code}) => {
    const {platform} = getRequestEvent()
    try {
        const pricingService = createPricingService(platform!)


        return !code ? await pricingService.getPricingForInvitation(invitationId) : pricingService.getPricingWithCoupon(invitationId, code);
    } catch (err) {
        Sentry.captureException(err);
        throw error(500, 'Failed to get pricing details');
    }
})

export const applyCoupon = command(pricingSchema, (args) => {
    getPricingDetail(args).refresh()
})
