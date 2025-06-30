import { serve } from 'std/http/server';
import * as Sentry from '@sentry/deno';
import Stripe from 'stripe';
import { db, sql } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { getRolesFromSession } from '../_shared/getRolesFromSession.ts';

// Initialize Sentry
Sentry.init({
	dsn: Deno.env.get('SENTRY_DSN'),
	environment: Deno.env.get('ENVIRONMENT') || 'development',
	tracesSampleRate: 1.0
});

// Initialize Stripe client
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || '', {
	apiVersion: '2025-05-28.basil',
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient()
});

interface WorkshopData {
	id: string;
	capacity: number;
	batch_size: number;
	stripe_price_key: string | null;
	workshop_date: string;
	location: string;
	status: string;
}

interface WaitlistMember {
	id: string;
	email: string;
	user_profile_id: string;
	first_name: string;
	last_name: string;
	phone_number: string;
	initial_registration_date: string;
}

interface InviteResult {
	user_profile_id: string;
	email: string;
	success: boolean;
	error?: string;
	payment_link?: string;
}

serve(async (req) => {
	// Handle CORS
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	let workshop_id: string | undefined;
	
	try {
		// Parse request body
		const requestBody = await req.json();
		workshop_id = requestBody.workshop_id;
		
		if (!workshop_id) {
			return new Response(
				JSON.stringify({ error: 'Missing workshop_id' }),
				{ status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
			);
		}

		console.log(`Starting workshop inviter for workshop: ${workshop_id}`);

		// Step 1: Fetch Workshop data
		const workshop = await fetchWorkshopData(workshop_id);
		if (!workshop) {
			return new Response(
				JSON.stringify({ error: 'Workshop not found' }),
				{ status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
			);
		}

		console.log(`Workshop found: ${workshop.id}, capacity: ${workshop.capacity}, batch_size: ${workshop.batch_size}`);

		// Step 2: Count current attendees
		const currentAttendees = await countCurrentAttendees(workshop_id);
		console.log(`Current attendees: ${currentAttendees}`);

		// Step 3: Calculate available slots
		const availableSlots = workshop.capacity - currentAttendees;
		console.log(`Available slots: ${availableSlots}`);

		if (availableSlots <= 0) {
			console.log('Workshop is already full, invalidating all pending links');
			await invalidateAllPendingLinks(workshop_id); // No exclusions needed when workshop is already full
			return new Response(
				JSON.stringify({ 
					message: 'Workshop is full', 
					available_slots: availableSlots,
					invalidated_links: true 
				}),
				{ status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
			);
		}

		// Step 4: Fetch waitlist in priority order (excluding those already in workshop_attendees)
		const waitlistMembers = await fetchWaitlistMembers(workshop_id);
		console.log(`Found ${waitlistMembers.length} waitlist members available for invitation`);

		// Step 5: Select batch (up to batch_size or available slots, whichever is less)
		const batchSize = Math.min(workshop.batch_size, availableSlots, waitlistMembers.length);
		const selectedMembers = waitlistMembers.slice(0, batchSize);
		console.log(`Selected batch size: ${batchSize}`);

		if (selectedMembers.length === 0) {
			return new Response(
				JSON.stringify({ 
					message: 'No eligible waitlist members found for invitation',
					available_slots: availableSlots
				}),
				{ status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
			);
		}

		// Step 6: Process each attendee (create payment links and insert records)
		const results: InviteResult[] = [];
		let successCount = 0;

		for (const member of selectedMembers) {
			const result = await processAttendeeInvitation(workshop, member);
			results.push(result);
			
			if (result.success) {
				successCount++;
				// Step 7: Print intended email to console
				printIntendedEmail(workshop, member, result.payment_link!);
			} else {
				console.error(`Failed to process invitation for ${member.email}: ${result.error}`);
			}
		}

		// Step 8: Check if workshop is now full and invalidate remaining links
		const finalAttendeeCount = currentAttendees + successCount;
		if (finalAttendeeCount >= workshop.capacity) {
			console.log('Workshop is now full, invalidating all remaining pending links (excluding current batch)');
			const currentBatchUserIds = results
				.filter(result => result.success)
				.map(result => result.user_profile_id);
			await invalidateAllPendingLinks(workshop_id, currentBatchUserIds);
		}

		// Return results
		return new Response(
			JSON.stringify({
				success: true,
				workshop_id,
				batch_size: batchSize,
				processed: results.length,
				successful_invites: successCount,
				failed_invites: results.length - successCount,
				workshop_full: finalAttendeeCount >= workshop.capacity,
				results
			}),
			{ status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
		);

	} catch (error) {
		console.error('Workshop inviter error:', error);
		Sentry.captureException(error, {
			tags: {
				function: 'workshop_inviter_main',
				workshop_id: workshop_id || 'unknown'
			},
			extra: {
				request_body: JSON.stringify({ workshop_id }),
				timestamp: new Date().toISOString()
			}
		});
		
		return new Response(
			JSON.stringify({ 
				error: 'Internal server error',
				message: error instanceof Error ? error.message : String(error)
			}),
			{ status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
		);
	}
});

async function fetchWorkshopData(workshop_id: string): Promise<WorkshopData | null> {
	try {
		const result = await db
			.selectFrom('workshops')
			.select(['id', 'capacity', 'batch_size', 'stripe_price_key', 'workshop_date', 'location', 'status'])
			.where('id', '=', workshop_id)
			.executeTakeFirst();
		
		return result || null;
	} catch (error) {
		console.error(`Error fetching workshop data for ${workshop_id}:`, error);
		Sentry.captureException(error, {
			tags: {
				function: 'fetchWorkshopData',
				workshop_id
			}
		});
		throw error; // Re-throw to be handled by main catch block
	}
}

async function countCurrentAttendees(workshop_id: string): Promise<number> {
	try {
		const result = await db
			.selectFrom('workshop_attendees')
			.select(sql`count(*)`.as('count'))
			.where('workshop_id', '=', workshop_id)
			.where('status', 'in', ['invited', 'confirmed', 'attended'])
			.executeTakeFirst();
		
		return Number(result?.count || 0);
	} catch (error) {
		console.error(`Error counting current attendees for workshop ${workshop_id}:`, error);
		Sentry.captureException(error, {
			tags: {
				function: 'countCurrentAttendees',
				workshop_id
			}
		});
		throw error; // Re-throw to be handled by main catch block
	}
}

async function fetchWaitlistMembers(workshop_id: string): Promise<WaitlistMember[]> {
	try {
		// Fetch waitlist members who have completed the workshop and are not already in this workshop
		const result = await sql<WaitlistMember>`
			SELECT 
				w.id,
				w.email,
				up.id as user_profile_id,
				up.first_name,
				up.last_name,
				up.phone_number,
				w.initial_registration_date
			FROM waitlist w
			JOIN user_profiles up ON up.waitlist_id = w.id
			WHERE w.status = 'completed'
			AND up.id NOT IN (
				SELECT user_profile_id 
				FROM workshop_attendees 
				WHERE workshop_id = ${workshop_id}
			)
			ORDER BY w.initial_registration_date ASC
		`.execute(db);
		
		return result.rows;
	} catch (error) {
		console.error(`Error fetching waitlist members for workshop ${workshop_id}:`, error);
		Sentry.captureException(error, {
			tags: {
				function: 'fetchWaitlistMembers',
				workshop_id
			}
		});
		throw error; // Re-throw to be handled by main catch block
	}
}

async function processAttendeeInvitation(
	workshop: WorkshopData, 
	member: WaitlistMember
): Promise<InviteResult> {
	try {
		// Create Stripe payment link if stripe_price_key is available
		let paymentLink: string | null = null;
		let paymentLinkId: string | null = null;
		
		if (workshop.stripe_price_key) {
			try {
				// Create Stripe Payment Link
				const stripePaymentLink = await stripe.paymentLinks.create({
					line_items: [
						{
							price: workshop.stripe_price_key,
							quantity: 1,
						},
					],
					after_completion: {
						type: 'hosted_confirmation',
						hosted_confirmation: {
                            custom_message: `Thank you! Your payment has been received and your place is confirmed.`,
                        },
					},
					allow_promotion_codes: true,
					billing_address_collection: 'auto',
					phone_number_collection: {
						enabled: true,
					},
					metadata: {
						workshop_id: workshop.id,
						user_profile_id: member.user_profile_id,
						attendee_name: `${member.first_name} ${member.last_name}`,
						attendee_email: member.email,
					},
				});
				
				paymentLink = stripePaymentLink.url;
				paymentLinkId = stripePaymentLink.id;
			} catch (stripeError) {
				console.error(`Stripe error for ${member.email}:`, stripeError);
				Sentry.captureException(stripeError, {
					tags: {
						function: 'processAttendeeInvitation',
						error_source: 'stripe_payment_link_creation',
						workshop_id: workshop.id,
						member_email: member.email
					},
					extra: {
						stripe_price_key: workshop.stripe_price_key,
						member_user_profile_id: member.user_profile_id,
						workshop_date: workshop.workshop_date
					}
				});
				// Continue without payment link - admin can handle manually
			}
		}

		// Insert into workshop_attendees table
		await db
			.insertInto('workshop_attendees')
			.values({
				workshop_id: workshop.id,
				user_profile_id: member.user_profile_id,
				status: 'invited',
				priority: 0, // Default priority for batch invites
				invited_at: new Date().toISOString(),
				payment_url_token: paymentLinkId, // Store the payment link ID
			})
			.execute();

		return {
			user_profile_id: member.user_profile_id,
			email: member.email,
			success: true,
			payment_link: paymentLink || undefined,
		};

	} catch (error) {
		console.error(`Error processing invitation for ${member.email}:`, error);
		Sentry.captureException(error, {
			tags: {
				function: 'processAttendeeInvitation',
				workshop_id: workshop.id,
				member_email: member.email
			},
			extra: {
				member_user_profile_id: member.user_profile_id,
				workshop_capacity: workshop.capacity,
				workshop_date: workshop.workshop_date
			}
		});
		return {
			user_profile_id: member.user_profile_id,
			email: member.email,
			success: false,
			error: error instanceof Error ? error.message : String(error),
		};
	}
}

async function invalidateAllPendingLinks(workshop_id: string, excludeUserIds: string[] = []): Promise<void> {
	try {
		// Get all invited attendees with payment links that need to be invalidated (excluding current batch)
		let query = db
			.selectFrom('workshop_attendees')
			.select(['payment_url_token', 'user_profile_id'])
			.where('workshop_id', '=', workshop_id)
			.where('status', '=', 'invited')
			.where('payment_url_token', 'is not', null);
		
		// Exclude users from current batch if provided
		if (excludeUserIds.length > 0) {
			query = query.where('user_profile_id', 'not in', excludeUserIds);
		}
		
		const pendingAttendees = await query.execute();

		// Deactivate each payment link in Stripe
		const deactivationPromises = pendingAttendees
			.filter(attendee => attendee.payment_url_token)
			.map(async (attendee) => {
				try {
					await stripe.paymentLinks.update(attendee.payment_url_token!, {
						active: false
					});
					console.log(`Deactivated Stripe payment link: ${attendee.payment_url_token}`);
				} catch (stripeError) {
					console.error(`Failed to deactivate payment link ${attendee.payment_url_token}:`, stripeError);
					// Continue with other links even if one fails
				}
			});

		// Execute all deactivations in parallel
		await Promise.allSettled(deactivationPromises);

		// Mark all pending/invited attendees as cancelled in the database (excluding current batch)
		let updateQuery = db
			.updateTable('workshop_attendees')
			.set({ 
				status: 'cancelled',
				payment_url_token: null // Clear the token to invalidate app-level access
			})
			.where('workshop_id', '=', workshop_id)
			.where('status', '=', 'invited');
		
		// Exclude users from current batch if provided
		if (excludeUserIds.length > 0) {
			updateQuery = updateQuery.where('user_profile_id', 'not in', excludeUserIds);
		}
		
		await updateQuery.execute();

		console.log(`Invalidated ${pendingAttendees.length} pending payment links for workshop ${workshop_id}`);
	} catch (error) {
		console.error('Error invalidating pending links:', error);
		Sentry.captureException(error);
	}
}

function printIntendedEmail(workshop: WorkshopData, member: WaitlistMember, paymentLink: string): void {
	const workshopDate = new Date(workshop.workshop_date).toLocaleDateString('en-IE', {
		weekday: 'long',
		year: 'numeric',
		month: 'long',
		day: 'numeric',
		hour: '2-digit',
		minute: '2-digit'
	});

	console.log(`
================================================================================
INTENDED EMAIL FOR: ${member.email}
================================================================================
To: ${member.email}
From: noreply@dublinhema.ie
Subject: 🗡️ You're Invited to Dublin HEMA Club Beginner's Workshop!

Dear ${member.first_name},

Great news! You've been invited to join our Beginner's Workshop at Dublin HEMA Club!

📅 Date & Time: ${workshopDate}
📍 Location: ${workshop.location}
💰 Payment Link: ${paymentLink || 'Payment will be handled separately'}

This is your opportunity to experience Historical European Martial Arts in a safe, 
welcoming environment. Our experienced instructors will guide you through the basics 
of medieval swordsmanship.

What to expect:
- Introduction to HEMA and safety protocols
- Basic sword handling techniques
- Simple combat exercises
- All equipment provided

Please complete your payment using the link above to secure your spot. 
Spaces are limited and allocated on a first-come, first-served basis.

If you have any questions or need to make special arrangements, please contact us 
at beginners@dublinhema.ie or reply to this email.

We're excited to welcome you to the Dublin HEMA Club community!

Best regards,
The Dublin HEMA Club Team

================================================================================
END EMAIL
================================================================================
	`);
} 