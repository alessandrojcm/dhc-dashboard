import * as v from 'valibot';

export const settingsSchema = v.object({
	insuranceFormLink: v.pipe(
		v.string(),
		v.nonEmpty('Please enter the HEMA Insurance Form link.'),
		v.url('Please enter a valid URL.')
	)
});

export type MemberSettings = v.InferInput<typeof settingsSchema>;
export type MemberSettingsOutput = v.InferOutput<typeof settingsSchema>;

export default settingsSchema;
