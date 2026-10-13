import { valibotSchema } from "@ai-sdk/valibot";
import { getDayOfWeek } from "@internationalized/date";
import { generateObject } from "ai";
import * as v from "valibot";
import { GROQ_API_KEY } from "$app/env/private";
import {
	dublinInstant,
	dublinToday,
	dublinTodayCalendarDate,
	formatDublinDateLong,
	formatDublinTime,
} from "#lib/club-calendar.js";
import {
	BaseWorkshopSchema,
	CreateWorkshopSchema,
	type CreateWorkshopInput,
} from "#lib/schemas/workshop.js";

/**
 * What the model returns: a draft workshop on the Dublin clock. The day is a
 * civil date and the times are Dublin wall-clock readings, which the server
 * turns into instants with `dublinInstant`; the model never works out a UTC
 * offset, which language models get wrong around the clock changes. Prices
 * are in cents.
 *
 * The same draft travels in the create page's `?generated=` parameter.
 */
export const LLMCreateWorkshopSchema = v.object({
	...v.omit(BaseWorkshopSchema, ["workshop_date", "workshop_end_date"]).entries,
	workshop_date: v.pipe(
		v.string(),
		v.isoDate(),
		v.description("The day of the workshop in Dublin, as YYYY-MM-DD."),
	),
	start_time: v.pipe(
		v.string(),
		v.isoTime(),
		v.description("The Dublin start time, 24-hour HH:MM."),
	),
	end_time: v.pipe(
		v.string(),
		v.isoTime(),
		v.description(
			"The Dublin end time, 24-hour HH:MM, on the same day and after the start time.",
		),
	),
});

export type WorkshopDraft = v.InferOutput<typeof LLMCreateWorkshopSchema>;

/** A civil date `days` after `now`'s Dublin today. */
function dublinDaysAfter(now: Date, days: number): string {
	return dublinTodayCalendarDate(now).add({ days }).toString();
}

/** Days from `now`'s Dublin today to the next Saturday, never today itself. */
function daysToNextSaturday(now: Date): number {
	const weekday = getDayOfWeek(dublinTodayCalendarDate(now), "en-US");
	return (6 - weekday + 7) % 7 || 7;
}

function example(draft: v.InferInput<typeof LLMCreateWorkshopSchema>) {
	return JSON.stringify(v.parse(LLMCreateWorkshopSchema, draft));
}

/**
 * The system prompt, built for the Dublin day and time at `now`: the model
 * reads "today", "tomorrow" and "next Saturday" against the club's calendar,
 * whatever the server's own clock zone.
 */
export function workshopGeneratorSystemPrompt(now: Date = new Date()): string {
	const nowIso = now.toISOString();
	const nextSaturday = daysToNextSaturday(now);
	return `
	<role>
	You are an assistant for a Historical European Martial Arts (HEMA) club based in Dublin Ireland, 
	your task is to help the workshop organizer to create workshops in the clubs management system.
	
	A workshop is an extra curricular activity that takes place outside regular training. This are often
	paid activities. You will take the instructions from the organizer and generate structured output
	to save in the database. Check the JSON schema format you are given. Prices are given in whole numbers,
	but you need to convert them to cents.
	Today in Dublin is ${formatDublinDateLong(nowIso)} (${dublinToday(now)}), and the time in Dublin is ${formatDublinTime(nowIso)}.
	Our permanent venue (the centre) is St Catherine's Sport Centre in Marrowbone Lane, Dublin 8. If no venue is specified, assume this is the venue.
	
	All dates and times are in Dublin. Give the day of the workshop as a date in YYYY-MM-DD format, and the
	start and end times as 24-hour HH:MM times on that day (2pm is 14:00). Never give a time zone or offset.
	Assume workshops are private by default. Assume we don't want to
	announce workshops on Discord by default. Assume we don't want to announce workshops by email by default.
	The default refund deadline is 3 days, a workshop cannot take place today or before today.
	
	If a workshop is public (availble to everyone, available to non members), then the price_non_member is equal to the price_member unless
	the user specifies different pricing for each.
	
	If the user says to 'announce everywhere', then the workshop will be announced on Discord and by email.
	
	</role>
	<examples>
	Create a workshop about building your own plastron. Next Saturday from 2pm to 3pm, cost is 20 euro maximum 20 people it will be at the centre.
	Output: 
	${example({
		title: "Create your own plastron",
		description: "You will learn to create your own plastron",
		location: "St Catherines Sport Centre",
		workshop_date: dublinDaysAfter(now, nextSaturday),
		start_time: "14:00",
		end_time: "15:00",
		max_capacity: 20,
		price_member: 2000,
		refund_deadline_days: 3,
	})}
	
	Create a workshop about footwork. tomorrow 2pm to 3pm, 20 euro, available to everyone, announce everywhere
	Output: 
	${example({
		title: "Footwork workshop",
		description: "You will footwork techniques",
		location: "St Catherines Sport Centre",
		workshop_date: dublinDaysAfter(now, 1),
		start_time: "14:00",
		end_time: "15:00",
		max_capacity: 20,
		price_member: 2000,
		refund_deadline_days: 3,
		price_non_member: 2000,
		is_public: true,
		announce_discord: true,
		announce_email: true,
	})}
	
	Create a workshop about wrestling. saturday next week 10am to 4pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere
	Output: 
	${example({
		title: "Wrestling workshop",
		description: "You will learn core wrestling techniques for HEMA",
		location: "St Catherines Sport Centre",
		workshop_date: dublinDaysAfter(now, nextSaturday + 7),
		start_time: "10:00",
		end_time: "16:00",
		max_capacity: 20,
		price_member: 3000,
		refund_deadline_days: 3,
		price_non_member: 3500,
		is_public: true,
		announce_discord: true,
		announce_email: true,
	})}
	
	If the user enters and invalid query, for example, they set the start date before the end date, you will reply with:
	
	Input: Create a workshop about wrestling. tomorrow 3pm to 2 pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere
	Output: 
	{
		success: false,
		message: "End time cannot be before start time"
	}
	
	Input: Create a workshop about wrestling. today 3pm to 2 pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere
	Output:
	{
		success: false,
		message: "Workshop cannot be scheduled for today"
	}
	</examples>
	`;
}

/**
 * A draft (from the model, or parsed back from the create page's URL with
 * `LLMCreateWorkshopSchema`) as the workshop form's values: Dublin date and
 * times become instants, cents become euros. Anything the draft cannot
 * honestly become fails: an impossible date or time, an end at or before the
 * start, or a start on Dublin's today.
 */
export function coerceToCreateWorkshopSchema(
	draft: WorkshopDraft,
): { success: true; output: CreateWorkshopInput } | { success: false } {
	const { workshop_date, start_time, end_time, ...rest } = draft;
	const start = dublinInstant(workshop_date, start_time);
	const end = dublinInstant(workshop_date, end_time);
	if (start === undefined || end === undefined) return { success: false };
	const result = v.safeParse(CreateWorkshopSchema, {
		...rest,
		workshop_date: new Date(start),
		workshop_end_date: new Date(end),
		price_member: rest.price_member / 100,
		price_non_member: rest.price_non_member
			? rest.price_non_member / 100
			: undefined,
	});
	return result.success
		? { success: true, output: result.output }
		: { success: false };
}

export async function generateWorkshopData(
	prompt: string,
	signal?: AbortSignal,
	now: Date = new Date(),
) {
	const model = import.meta.env.DEV
		? await import("ollama-ai-provider-v2").then(({ ollama }) =>
				ollama("qwen3:8b"),
			)
		: await import("@ai-sdk/groq").then(({ groq }) =>
				groq("meta-llama/llama-4-scout-17b-16e-instruct"),
			);
	return generateObject({
		model,
		schema: valibotSchema(LLMCreateWorkshopSchema),
		system: workshopGeneratorSystemPrompt(now),
		temperature: 0.5,
		prompt,
		...(GROQ_API_KEY && { apiKey: GROQ_API_KEY }),
		...(signal && { abortSignal: signal }),
		experimental_repairText: ({ text, error }) => {
			try {
				if (error) {
					return {
						success: false,
						error: "There was an error generating this workshop data",
					};
				}
				return JSON.parse(text);
			} catch {
				return {
					success: false,
					error: "There was an error generating this workshop data",
				};
			}
		},
	});
}
