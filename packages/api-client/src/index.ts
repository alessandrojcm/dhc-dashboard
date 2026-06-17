// @dhc/api-client - Generated TypeScript SDK for DHC Dashboard API
//
// Re-exports everything from the generated client.
// Use `configureClient()` to set base URL and auth token.

// Generated SDK functions & types
export {
	healthIndex,
	invitationsCreate,
	invitationsResend,
	stripeWebhooksCreate,
	waitlistStatus,
	type Options,
} from "./client/sdk.gen";
export type {
	ClientOptions,
	HealthIndexData,
	HealthIndexResponse,
	HealthIndexResponses,
	InvitationCreateInvite,
	InvitationCreateRequest,
	InvitationCreateResponse,
	InvitationResendCreateRequest,
	InvitationResendCreateResponse,
	InvitationsCreateData,
	InvitationsCreateError,
	InvitationsCreateErrors,
	InvitationsCreateResponse,
	InvitationsCreateResponses,
	InvitationsResendData,
	InvitationsResendError,
	InvitationsResendErrors,
	InvitationsResendResponse,
	InvitationsResendResponses,
	StripeWebhooksCreateData,
	StripeWebhooksCreateError,
	StripeWebhooksCreateErrors,
	StripeWebhooksCreateResponse,
	StripeWebhooksCreateResponses,
	WaitlistStatusData,
	WaitlistStatusResponse,
	WaitlistStatusResponse2,
	WaitlistStatusResponses,
} from "./client/types.gen";

// Valibot schemas (runtime validation)
export {
	vHealthIndexResponse,
	vInvitationCreateInvite,
	vInvitationCreateRequest,
	vInvitationCreateResponse,
	vInvitationResendCreateRequest,
	vInvitationResendCreateResponse,
	vInvitationsCreateBody,
	vInvitationsCreateResponse,
	vInvitationsResendBody,
	vInvitationsResendResponse,
	vStripeWebhooksCreateBody,
	vStripeWebhooksCreateResponse,
	vWaitlistStatusResponse,
	vWaitlistStatusResponse2,
} from "./client/valibot.gen";

// TanStack Svelte Query helpers
export {
	healthIndexOptions,
	healthIndexQueryKey,
	invitationsCreateMutation,
	invitationsCreateMutationKey,
	invitationsResendMutation,
	invitationsResendMutationKey,
	stripeWebhooksCreateMutation,
	stripeWebhooksCreateMutationKey,
	waitlistStatusOptions,
	waitlistStatusQueryKey,
	type QueryKey,
} from "./client/@tanstack/svelte-query.gen";

// Client configuration
export { configureClient, getClient } from "./config";
export type { ClientConfig, SupabaseJwtGetter } from "./config";

// Low-level client (for interceptors, custom requests)
export { client } from "./client/client.gen";
