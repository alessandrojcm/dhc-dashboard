import dayjs from 'dayjs';
import * as v from 'valibot';
import { generateObject } from 'ai';
import { valibotSchema } from '@ai-sdk/valibot';
import { BaseWorkshopSchema, CreateWorkshopSchema } from '$lib/schemas/workshops';
import { env } from '$env/dynamic/private';

export const LLMCreateWrokshopSchema = v.object({
	...v.omit(BaseWorkshopSchema, ['workshop_date', 'workshop_end_date']).entries,
	workshop_date: v.pipe(v.string(), v.isoTimestamp()),
	workshop_end_date: v.pipe(v.string(), v.isoTimestamp())
});

const system = `
	<role>
	You are an assistant for a Historical European Martial Arts (HEMA) club based in Dublin Ireland, 
	your task is to help the workshop organizer to create workshops in the clubs management system.
	
	A workshop is an extra curricular activity that takes place outside regular training. This are often
	paid activities. You will take the instructions from the organizer and generate structured output
	to save in the database. Check the JSON schema format you are given. Prices are given in whole numbers,
	but you need to convert them to cents. Today is ${dayjs().format('dddd MMMM D YYYY, h:mm:ss a')}.
	Our permanent venue (the centre) is St Catherine's Sport Centre in Marrowbone Lane, Dublin 8. If no venue is specified, assume this is the venue.
	
	Dates are always given in ISO 8601 format. Assume workshops are private by default. Assume we don't want to
	announce workshops on Discord by default. Assume we don't want to announce workshops by email by default.
	The default refund deadline is 3 days, a workshop start date cannot be set before today.
	
	If a workshop is public (availble to everyone, available to non members), then the price_non_member is equal to the price_member unless
	the user specifies different pricing for each.
	
	If the user says to 'announce everywhere', then the workshop will be announced on Discord and by email.
	
	</role>
	<examples>
	Create a workshop about building your own plastron. Next Saturday from 2pm to 3pm, cost is 20 euro maximum 20 people it will be at the centre.
	Output: 
	${JSON.stringify(
		v.parse(LLMCreateWrokshopSchema, {
			title: 'Create your own plastron',
			description: 'You will learn to create your own plastron',
			location: 'St Catherines Sport Centre',
			workshop_date: dayjs().day(6).hour(14).second(0).minute(0).millisecond(0).toISOString(),
			workshop_end_date: dayjs().day(6).hour(15).second(0).minute(0).millisecond(0).toISOString(),
			max_capacity: 20,
			price_member: 2000,
			refund_deadline_days: 3
		} as v.InferInput<typeof LLMCreateWrokshopSchema>)
	)}
	
	Create a workshop about footwork. tomorrow 2pm to 3pm, 20 euro, available to everyone, announce everywhere
	Output: 
	${JSON.stringify(
		v.parse(LLMCreateWrokshopSchema, {
			title: 'Footwork workshop',
			description: 'You will footwork techniques',
			location: 'St Catherines Sport Centre',
			workshop_date: dayjs().add(1, 'day').hour(14).minute(0).millisecond(0).toISOString(),
			workshop_end_date: dayjs().add(1, 'day').hour(15).minute(0).millisecond(0).toISOString(),
			max_capacity: 20,
			price_member: 2000,
			refund_deadline_days: 3,
			price_non_member: 2000,
			is_public: true,
			announce_discord: true,
			announce_email: true
		} as v.InferInput<typeof LLMCreateWrokshopSchema>)
	)}
	
	Create a workshop about wrestling. saturday next week 10am to 4pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere
	Output: 
	${JSON.stringify(
		v.parse(LLMCreateWrokshopSchema, {
			title: 'Wrestling workshop',
			description: 'You will learn core wrestling techniques for HEMA',
			location: 'St Catherines Sport Centre',
			workshop_date: dayjs().add(1, 'week').day(6).hour(10).minute(0).millisecond(0).toISOString(),
			workshop_end_date: dayjs()
				.add(1, 'week')
				.day(6)
				.hour(16)
				.minute(0)
				.millisecond(0)
				.toISOString(),
			max_capacity: 20,
			price_member: 3000,
			refund_deadline_days: 3,
			price_non_member: 3500,
			is_public: true,
			announce_discord: true,
			announce_email: true
		} as v.InferInput<typeof LLMCreateWrokshopSchema>)
	)}
	
	If the user enters and invalid query, for example, they set the start date before the end date, you will reply with:
	
	Input: Create a workshop about wrestling. tomorrow 3pm to 2 pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere
	Output: 
	{
		success: false,
		message: "Start time cannot be before end time"
	}
	
	Input: Create a workshop about wrestling. today 3pm to 2 pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere
	Output:
	{
		success: false,
		message: "Start time cannot today"
	}
	</examples>
	`;

export function coerceToCreateWorkshopSchema(
	output: v.InferInput<typeof LLMCreateWrokshopSchema>
): v.SafeParseResult<typeof CreateWorkshopSchema> {
	return v.safeParse(CreateWorkshopSchema, {
		...output,
		workshop_date: dayjs(output.workshop_date).toDate(),
		workshop_end_date: dayjs(output.workshop_end_date).toDate(),
		price_member: output.price_member / 100,
		price_non_member: output.price_non_member ? output.price_non_member / 100 : undefined
	});
}

export async function generateWorkshopData(prompt: string, signal?: AbortSignal) {
	const model = import.meta.env.DEV
		? await import('ollama-ai-provider').then(({ ollama }) => ollama('qwen3:8b'))
		: await import('@ai-sdk/groq').then(({ groq }) =>
				groq('meta-llama/llama-4-scout-17b-16e-instruct')
			);
	return generateObject({
		model,
		schema: valibotSchema(LLMCreateWrokshopSchema),
		system,
		temperature: 0.5,
		prompt,
		...(env?.GROQ_API_KEY && { apiKey: env.GROQ_API_KEY }),
		...(signal && { abortSignal: signal }),
		experimental_repairText: ({ text, error }) => {
			try {
				if (error) {
					return {
						success: false,
						error: 'There was an error generating this workshop data'
					};
				}
				return JSON.parse(text);
			} catch {
				return {
					success: false,
					error: 'There was an error generating this workshop data'
				};
			}
		}
	});
}
