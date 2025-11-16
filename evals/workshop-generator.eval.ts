import { evalite } from 'evalite';
import type * as v from 'valibot';
import {
	coerceToCreateWorkshopSchema,
	generateWorkshopData,
	type LLMCreateWrokshopSchema
} from '../src/lib/server/workshop-generator';

evalite('Workshop generator eval', {
	data: () => [
		{
			input:
				'create your own sword at the forge, tomorrow from 3pm to 6 pm, 20 euro, 20 people, announce on email'
		},
		{
			input:
				'footwork workshop, next saturday, 20 euro, 20 people, availabel to everyone, announce on email'
		},
		{
			input:
				'Create a workshop about wrestling. today 3pm to 2 pm, 30 euro, 25 euro for the public, available to everyone, announce everywhere',
			expected: {
				success: false,
				message: 'Start time cannot today'
			}
		}
	],
	scorers: [
		{
			name: 'Structured output',
			description: 'Checks the output matches the crate workshop schema',
			scorer: ({
				output,
				expected
			}: {
				output: v.InferOutput<typeof LLMCreateWrokshopSchema>;
				expected?: { success: boolean; message: string };
			}) => {
				if (expected) {
					return JSON.stringify(output) === JSON.stringify(expected) ? 1 : 0;
				}
				const result = coerceToCreateWorkshopSchema(output);
				console.log(result.issues);

				return result.success ? 1 : 0;
			}
		}
	],
	task: (input) => generateWorkshopData(input).then((a) => a.object)
});
