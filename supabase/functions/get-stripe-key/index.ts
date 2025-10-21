// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.
import { createClient } from '@supabase/supabase-js';
import { corsHeaders } from '../_shared/cors.ts';
import { getRolesFromSession } from '../_shared/getRolesFromSession.ts';
// Setup type definitions for built-in Supabase Runtime APIs
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

const currentKey = Deno.env.get('TAP_TO_PAY_KEY');

Deno.serve(async (req) => {
	// Initialize Supabase client with anon key for authentication
	const supabaseClient = createClient(
		Deno.env.get('SUPABASE_URL') ?? '',
		Deno.env.get('SUPABASE_ANON_KEY') ?? ''
	);

	// Get the authorization header and validate the token
	const authHeader = req.headers.get('Authorization');
	if (!authHeader) {
		return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
			status: 401,
			headers: { 'Content-Type': 'application/json', ...corsHeaders }
		});
	}

	const token = authHeader.replace('Bearer ', '');
	const { data: userData, error: authError } = await supabaseClient.auth.getUser(token);

	if (authError || !userData?.user) {
		return new Response(JSON.stringify({ error: 'Unauthorized', details: authError?.message }), {
			status: 403,
			headers: { 'Content-Type': 'application/json', ...corsHeaders }
		});
	}
	// Validate user permissions (only admins, presidents, committee coordinators)
	const roles = await getRolesFromSession(token);
	const userRoles = new Set(roles);

	const ALLOWED_ROLES = new Set(['admin', 'president', 'committee_coordinator']);
	const hasPermission = [...userRoles].some(
		(role) => typeof role === 'string' && ALLOWED_ROLES.has(role)
	);

	if (!hasPermission) {
		return new Response(
			JSON.stringify({
				error: 'Insufficient permissions to create invitations'
			}),
			{
				status: 403,
				headers: { 'Content-Type': 'application/json', ...corsHeaders }
			}
		);
	}
	return new Response(JSON.stringify({ stripeKey: currentKey }), {
		status: 200,
		headers: { 'Content-Type': 'application/json', ...corsHeaders }
	});
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/get-stripe-key' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"name":"Functions"}'

*/
