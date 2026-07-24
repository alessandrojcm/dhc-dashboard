import dayjs from "dayjs";

export interface RefundEligibilityResult {
	isEligible: boolean;
	reason?: string;
	daysUntilDeadline?: number;
}

export function checkRefundEligibility(
	startDate: string | null | undefined,
	refundDays: number | null | undefined,
	workshopStatus: string,
	registrationStatus: string,
): RefundEligibilityResult {
	// Check if registration is already refunded
	if (registrationStatus === "refunded") {
		return {
			isEligible: false,
			reason: "Registration already refunded",
		};
	}

	// Check if workshop is finished
	if (workshopStatus === "finished") {
		return {
			isEligible: false,
			reason: "Cannot refund finished workshop",
		};
	}

	// Check refund deadline if specified
	if (refundDays !== null && refundDays !== undefined) {
		if (!startDate) {
			return {
				isEligible: false,
				reason: "Workshop start date unavailable",
			};
		}

		const refundDeadline = dayjs(startDate).subtract(refundDays, "days");
		const now = dayjs();

		if (now.isAfter(refundDeadline)) {
			return {
				isEligible: false,
				reason: "Refund deadline has passed",
			};
		}

		const daysUntilDeadline = refundDeadline.diff(now, "days");
		return {
			isEligible: true,
			daysUntilDeadline,
		};
	}

	// No refund deadline specified, eligible until workshop starts
	return {
		isEligible: true,
	};
}
