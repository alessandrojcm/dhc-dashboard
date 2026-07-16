import * as v from "valibot";

export const InsuranceFormLinkSchema = v.object({
	insuranceFormLink: v.pipe(
		v.string(),
		v.nonEmpty("Please enter the HEMA Insurance Form link."),
		v.url("Please enter a valid URL."),
	),
});

export type InsuranceFormLinkInput = v.InferOutput<
	typeof InsuranceFormLinkSchema
>;
