import type { BrowserContext } from 'playwright';
import { getSupabaseServiceClient } from "./setupFunctions";

export async function loginAsUser(context: BrowserContext, email: string) {
    const supabase = getSupabaseServiceClient();
		console.log('Supabase URL:', process.env.PUBLIC_SUPABASE_URL);

		const { data, error } = await supabase.auth.signInWithPassword({
			email,
			password: 'password'
		});

		if (error) throw error;
		if (!data.session) throw new Error('No session data returned');

		console.log('Sign-in successful, session:', data.session);

		// Extract project ref from SUPABASE_URL
		const projectRef = process.env.PUBLIC_SUPABASE_URL?.replace('http://', '').split('.').shift();
		if (!projectRef) throw new Error('Could not extract project ref from SUPABASE_URL');

		console.log('Project ref:', projectRef);
		console.log('Setting cookie with name:', `sb-${projectRef}-auth-token`);

		await context.addCookies([
			{
				name: `sb-${projectRef}-auth-token`,
				value: `base64-${btoa(JSON.stringify(data.session))}`,
				domain: '127.0.0.1',
				path: '/',
				httpOnly: false,
				secure: false,
				sameSite: 'Lax'
			}
		]);

		console.log('Cookie set successfully');
}