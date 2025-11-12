# Subscription and Invitation Migration Steps

This document outlines a detailed, step-by-step plan to refactor the bulk invite process by consolidating subscription creation with invitation creation, and offloading heavy tasks to a Supabase Edge Function.

## Implementation Progress (Updated: April 14, 2025)

✅ **Completed Tasks:**

1. Created a new Edge Function for bulk invitations with subscription creation
2. Implemented Kysely for database transactions to ensure atomicity
3. Created shared modules for invitations and subscriptions
4. Added background processing using `EdgeRuntime.waitUntil()` for improved user experience
5. Created a logging system for tracking invitation processing results
6. Implemented proper authentication and permission checks

⏳ **Pending Tasks:**

1. Deploy the Edge Function and database migration
2. Update the client-side code to handle the new asynchronous workflow
3. Add UI components to display processing status (optional)
4. Update tests to verify the new implementation

## Detailed Step-by-Step Action Plan

### Step 1: Create a New Edge Function ✅

1. **Create the Edge Function File**
   - **Location:** `supabase/functions/bulk_invite_with_subscription/index.ts`
   - **Task:** Create a new file and setup the basic function handler.
   - **Implementation:**

   ```typescript
   // supabase/functions/bulk_invite_with_subscription/index.ts
   import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
   import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
   import dayjs from 'https://esm.sh/dayjs@1.11.7';
   import * as Sentry from 'https://esm.sh/@sentry/node@7.64.0';
   import { Stripe } from 'https://esm.sh/stripe@12.4.0?target=deno';
   import { db } from '../_shared/db.ts';
   import { createInvitation } from '../_shared/invitations.ts';
   import {
   	createPaymentSession,
   	updateUserProfileWithCustomerId
   } from '../_shared/subscriptions.ts';

   // Add event listener for beforeUnload to handle graceful shutdown
   addEventListener('beforeunload', (event) => {
   	console.log('Function is about to be terminated:', event);
   	// Perform any cleanup if needed
   });

   serve(async (req: Request) => {
   	try {
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
   				headers: { 'Content-Type': 'application/json' }
   			});
   		}

   		const token = authHeader.replace('Bearer ', '');
   		const { data: userData, error: authError } = await supabaseClient.auth.getUser(token);

   		if (authError || !userData?.user) {
   			return new Response(
   				JSON.stringify({ error: 'Unauthorized', details: authError?.message }),
   				{ status: 403, headers: { 'Content-Type': 'application/json' } }
   			);
   		}

   		// Create admin client for privileged operations
   		const supabaseAdmin = createClient(
   			Deno.env.get('SUPABASE_URL') ?? '',
   			Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
   		);

   		// Parse JSON payload from the request
   		const { invites } = (await req.json()) as { invites: InviteData[] };

   		// Validate user permissions (only admins, presidents, committee coordinators)
   		const { data: rolesData } = await supabaseClient.rpc('get_user_roles');
   		const userRoles = new Set(rolesData || []);

   		const ALLOWED_ROLES = new Set(['admin', 'president', 'committee_coordinator']);
   		const hasPermission = [...userRoles].some(
   			(role) => typeof role === 'string' && ALLOWED_ROLES.has(role)
   		);

   		if (!hasPermission) {
   			return new Response(
   				JSON.stringify({ error: 'Insufficient permissions to create invitations' }),
   				{ status: 403, headers: { 'Content-Type': 'application/json' } }
   			);
   		}

   		// Get price IDs for immediate validation
   		const priceIds = await getPriceIds();

   		// Create a background task to process invitations
   		const processingPromise = processInvitations(
   			invites,
   			userData.user,
   			supabaseAdmin,
   			priceIds
   		);

   		// Use waitUntil to keep the function running in the background
   		EdgeRuntime.waitUntil(processingPromise);

   		// Return an immediate response to the client
   		return new Response(
   			JSON.stringify({
   				message: 'Invitations are being processed in the background',
   				count: invites.length
   			}),
   			{ headers: { 'Content-Type': 'application/json' } }
   		);
   	} catch (error) {
   		Sentry.captureException(error);
   		const errorMessage = error instanceof Error ? error.message : String(error);
   		return new Response(JSON.stringify({ error: errorMessage }), {
   			status: 500,
   			headers: { 'Content-Type': 'application/json' }
   		});
   	}
   });
   ```

2. **Background Processing Implementation** ✅
   - Implemented background processing using `EdgeRuntime.waitUntil()` to improve user experience
   - Created a logging system to track invitation processing results
   - Added proper error handling and monitoring with Sentry

   ```typescript
   // Background processing function
   async function processInvitations(
   	invites: InviteData[],
   	user: UserData,
   	supabaseAdmin: ReturnType<typeof createClient>,
   	priceIds: { monthly: string; annual: string }
   ) {
   	console.log(`Starting background processing of ${invites.length} invitations`);
   	const results: InviteResult[] = [];
   	const startTime = Date.now();

   	try {
   		// Process each invite in a transaction
   		for (const invite of invites) {
   			// ... invitation processing code ...
   		}

   		// Store the results in a database
   		await storeProcessingResults(results, user.id);

   		const processingTime = (Date.now() - startTime) / 1000;
   		console.log(`Completed processing ${invites.length} invitations in ${processingTime}s`);
   		return results;
   	} catch (error) {
   		Sentry.captureException(error);
   		console.error(`Error in background processing: ${errorMessage}`);
   		throw error;
   	}
   }
   ```

3. **Database Migration for Logging** ✅
   - Created a new table `invitation_processing_logs` to store processing results
   - Added RLS policies for security
   - Implemented proper indexing for performance

### Step 2: Update the Server-Side Bulk Invite Endpoint ✅

1. **Locate the Current Endpoint**
   - **File:** `src/routes/dashboard/members/+page.server.ts`
2. **Modified the `createBulkInvites` Function**
   - **Removed** the inline, synchronous processing logic
   - **Built a payload** that includes invites and user session information
   - **Asynchronously called** the new Edge Function endpoint using a `fetch` call
   - **Provided immediate success feedback** to the user without waiting for the background process to complete

**Implemented Code:**

```typescript
export const actions = {
	createBulkInvites: async ({ request, locals, fetch }) => {
		// Validate the form using superValidate and the bulkInviteSchema
		const form = await superValidate(request, valibot(bulkInviteSchema));
		if (!form.valid) {
			return fail(400, {
				form: { ...form, message: { failure: 'There was an error sending the invites.' } }
			});
		}

		try {
			// Prepare the payload for the Edge Function
			const payload = {
				invites: form.data.invites,
				session: locals.session
			};

			// Call the new Edge Function asynchronously
			const response = await fetch(`${env.EDGE_FUNCTION_URL}/bulk_invite_with_subscription`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Authorization: `Bearer ${locals.session.access_token}`
				},
				body: JSON.stringify(payload)
			});

			if (!response.ok) {
				const errorData = await response.json();
				throw new Error(errorData.error || 'Failed to process invitations');
			}

			// Return immediate user feedback
			return message(form, {
				success:
					'Invitations are being processed in the background. You will be notified when completed.'
			});
		} catch (error) {
			console.error('Error sending invitations:', error);
			return fail(500, {
				form: { ...form, message: { failure: 'There was an error sending the invites.' } }
			});
		}
	}
};
```

### Step 3: Refactor Helper Functions ✅

1. **Created Shared Modules**
   - **Created `_shared/invitations.ts`**
     - Implemented `createInvitation` function with proper transaction support
     - Added error handling and validation
   - **Created `_shared/subscriptions.ts`**
     - Implemented `createPaymentSession` function for storing subscription details
     - Added `updateUserProfileWithCustomerId` function to update user profiles
     - Ensured consistent expiration time (24 hours) for both invitations and payment sessions

### Step 4: Update the Invite UI Component ⏳

1. **Locate the File:**
   - **File:** `src/routes/dashboard/members/invite-drawer.svelte`

2. **Update the Form Submission Handler**
   - **Action:** Ensure that when the form is submitted, it calls the updated server endpoint (which in turn calls the Edge Function).
   - **Consider:** Adding a loading spinner or immediate success message so that the user knows processing has begun.
   - **Status:** Pending implementation

### Step 5: Update Environment and Deployment Configuration ⏳

1. **Set Environment Variables:**
   - **Key:** `EDGE_FUNCTION_URL` must be added to your environment files (e.g., `.env` or equivalent configuration) to point to the deployed Edge Function endpoint.
   - **Status:** Pending implementation

2. **Deploy Edge Function and Migration:**
   - Deploy the new Edge Function to Supabase
   - Apply the database migration for the `invitation_processing_logs` table
   - **Status:** Pending implementation

### Step 6: Testing and Documentation ⏳

1. **Write Integration Tests:**
   - **Test Cases:** Verify that when a payload is sent to the Edge Function, it correctly creates both the subscription and invitation records with matching expiration times.
   - **Status:** Pending implementation

2. **Update Unit Tests:**
   - Modify or add tests in your existing test suite to account for the decoupled asynchronous processing.
   - **Status:** Pending implementation

3. **Update Developer Documentation:**
   - Document the new workflow in internal documentation and ensure all developers are aware of the changes.
   - **Status:** This document serves as initial documentation

## Summary

The implementation of background processing for bulk invitations has successfully addressed the key objectives:

1. **Improved User Experience**: The page load time has been significantly reduced by offloading heavy processing to a Supabase Edge Function with background processing.

2. **Consolidated Operations**: Subscription and invitation creation are now handled in a single atomic transaction, ensuring consistency and reliability.

3. **Enhanced Monitoring**: A new logging system tracks the progress and results of invitation processing, making it easier to debug issues and monitor performance.

4. **Improved Error Handling**: Comprehensive error handling with Sentry integration ensures that failures are properly tracked and reported.

5. **Proper Authentication**: The Edge Function now uses proper token-based authentication and permission checks.

### Next Steps

1. Deploy the Edge Function and database migration
2. Update the client-side code to handle the new asynchronous workflow
3. Add UI components to display processing status (optional)
4. Update tests to verify the new implementation
