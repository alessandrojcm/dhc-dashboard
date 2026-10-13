/**
 * event-calendar's `buttonText` for the club calendars.
 *
 * Passed as a function, event-calendar calls it with each view's own labels
 * ("Previous month"/"Next month" in the month grid, "Previous week"/"Next
 * week" in the week list, the day popup's "Close"), so the arrows keep their
 * accessible names. A plain object would replace those labels and leave the
 * arrows unnamed.
 */
export function calendarButtonText<Labels extends object>(defaults: Labels) {
	return { ...defaults, today: "Today" };
}
