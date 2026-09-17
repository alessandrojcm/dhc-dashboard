import type {
	AcceptanceApiResult,
	AcceptanceView,
	InvitationAcceptanceStatus,
} from "$lib/invitation-acceptance/vocabulary";
import type {
	AcceptanceCookieStore,
	AcceptanceProof,
	InvitationAcceptanceApi,
	InvitationCredentials,
	PaymentSubmission,
	PricingApiResult,
	VerificationResult,
} from "./ports";

/**
 * In-memory adapters for the Invitation Acceptance ports. Test-only: they
 * script Phoenix answers per operation and record every requested effect so
 * boundary tests can assert on behaviour without Phoenix, Stripe, or SvelteKit.
 */

export type AcceptanceApiOperation = keyof InvitationAcceptanceApi;

export type RecordedApiCall = {
	op: AcceptanceApiOperation;
	proof: AcceptanceProof | undefined;
	payload?: InvitationCredentials | PaymentSubmission | { code?: string };
};

type OneOrMany<T> = T | T[];

type Script = {
	verify?: OneOrMany<VerificationResult>;
	show?: OneOrMany<AcceptanceApiResult>;
	continueAcceptance?: OneOrMany<AcceptanceApiResult>;
	submitPayment?: OneOrMany<AcceptanceApiResult>;
	retry?: OneOrMany<AcceptanceApiResult>;
	cancelDiscord?: OneOrMany<AcceptanceApiResult>;
	previewPricing?: OneOrMany<PricingApiResult>;
};

function queue<T>(answers: OneOrMany<T> | undefined): T[] {
	if (answers === undefined) return [];
	return Array.isArray(answers) ? [...answers] : [answers];
}

export function inMemoryAcceptanceApi(script: Script = {}) {
	const calls: RecordedApiCall[] = [];
	const queues = {
		verify: queue(script.verify),
		show: queue(script.show),
		continueAcceptance: queue(script.continueAcceptance),
		submitPayment: queue(script.submitPayment),
		retry: queue(script.retry),
		cancelDiscord: queue(script.cancelDiscord),
		previewPricing: queue(script.previewPricing),
	};

	function take<T>(answers: T[], call: RecordedApiCall): T {
		calls.push(call);
		const next = answers.shift();
		if (next === undefined) {
			throw new Error(`inMemoryAcceptanceApi: unscripted call to ${call.op}`);
		}
		return next;
	}

	const api: InvitationAcceptanceApi = {
		verify: async (proof, credentials) =>
			take(queues.verify, { op: "verify", proof, payload: credentials }),
		show: async (proof) => take(queues.show, { op: "show", proof }),
		continueAcceptance: async (proof) =>
			take(queues.continueAcceptance, { op: "continueAcceptance", proof }),
		submitPayment: async (proof, payment) =>
			take(queues.submitPayment, {
				op: "submitPayment",
				proof,
				payload: payment,
			}),
		retry: async (proof) => take(queues.retry, { op: "retry", proof }),
		cancelDiscord: async (proof) =>
			take(queues.cancelDiscord, { op: "cancelDiscord", proof }),
		previewPricing: async (proof, code) => {
			const call: RecordedApiCall = { op: "previewPricing", proof };
			if (code !== undefined) call.payload = { code };
			return take(queues.previewPricing, call);
		},
	};

	return { api, calls };
}

export type RecordedCookieEffect =
	| { type: "storeProof"; proof: AcceptanceProof }
	| { type: "clearProof" }
	| { type: "storeSignInPrefill"; invitationEmail: string };

export function recordingCookieStore(
	initial: { proof?: AcceptanceProof } = {},
) {
	let proof = initial.proof;
	const effects: RecordedCookieEffect[] = [];

	const cookies: AcceptanceCookieStore = {
		readProof: () => proof,
		storeProof(next) {
			proof = next;
			effects.push({ type: "storeProof", proof: next });
		},
		clearProof() {
			proof = undefined;
			effects.push({ type: "clearProof" });
		},
		storeSignInPrefill(invitationEmail) {
			effects.push({ type: "storeSignInPrefill", invitationEmail });
		},
	};

	return {
		cookies,
		effects,
		get proof() {
			return proof;
		},
	};
}

export const acceptanceView = (
	state: InvitationAcceptanceStatus,
	extra: Omit<AcceptanceView, "state"> = {},
	httpStatus = 200,
): AcceptanceApiResult => ({
	kind: "view",
	httpStatus,
	view: { state, ...extra },
});
