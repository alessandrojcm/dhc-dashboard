// THIS MODULE IS TO BE USED ON THE SERVER ONLY
import { createClient } from '@supabase/supabase-js';
import type { Database } from '$database';
import { env } from '$env/dynamic/private';
import { PUBLIC_SUPABASE_URL } from '$env/static/public';

const supabaseServiceClient = createClient<Database>(PUBLIC_SUPABASE_URL, env.SERVICE_ROLE_KEY, {
	auth: {
		persistSession: false,
		autoRefreshToken: false,
		detectSessionInUrl: false
	}
});

export { supabaseServiceClient };
