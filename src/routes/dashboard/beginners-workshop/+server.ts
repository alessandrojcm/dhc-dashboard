import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { getRolesFromSession, allowedToggleRoles } from '$lib/server/roles';
import { kysely, executeWithRLS } from '$lib/server/kysely';

export const POST: RequestHandler = async ({ locals }) => {
    try {
        const canToggleWaitlist =
            getRolesFromSession(locals.session!).intersection(allowedToggleRoles).size > 0;
        
        if (!canToggleWaitlist) {
            return json({ success: false }, { status: 403 });
        }

        const currentValue = await kysely
            .selectFrom('settings')
            .select('value')
            .where('key', '=', 'waitlist_open')
            .executeTakeFirstOrThrow();

        const newValue = currentValue.value === 'true' ? 'false' : 'true';

        await executeWithRLS({
            claims: locals.session!
        }, async (trx) => {
            await trx
                .updateTable('settings')
                .set({ value: newValue })
                .where('key', '=', 'waitlist_open')
                .execute();
        });

        return json({ success: true });
    } catch (error) {
        console.error('Error toggling waitlist:', error);
        return json({ success: false, error: 'Internal server error' }, { status: 500 });
    }
};
