<script lang="ts" module>
	import { type VariantProps, tv } from "tailwind-variants";
	export const badgeVariants = tv({
		base: "focus:ring-ring inline-flex select-none items-center rounded-md border px-2.5 py-0.5 text-xs font-semibold transition-colors focus:outline-hidden focus:ring-2 focus:ring-offset-2",
		variants: {
			variant: {
				default:
					"bg-primary text-primary-foreground hover:bg-primary/80 border-transparent shadow-sm",
				secondary:
					"bg-secondary text-secondary-foreground hover:bg-secondary/80 border-transparent",
				destructive:
					"bg-destructive text-destructive-foreground hover:bg-destructive/80 border-transparent shadow-sm",
				outline: "text-foreground",
				waiting: "bg-yellow-100 text-yellow-800 hover:bg-yellow-200",
				invited: "bg-blue-100 text-blue-800 hover:bg-blue-200",
				paid: "bg-green-100 text-green-800 hover:bg-green-200",
				deferred: "bg-purple-100 text-purple-800 hover:bg-purple-200",
				cancelled: "bg-gray-100 text-gray-800 hover:bg-gray-200",
				completed: "bg-emerald-100 text-emerald-800 hover:bg-emerald-200",
				no_reply: "bg-red-100 text-red-800 hover:bg-red-200"
			},
		},
		defaultVariants: {
			variant: "default",
		},
	});

	export type BadgeVariant = VariantProps<typeof badgeVariants>["variant"];
</script>

<script lang="ts">
	import type { WithElementRef } from "bits-ui";
	import type { HTMLAnchorAttributes } from "svelte/elements";
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		href,
		class: className,
		variant = "default",
		children,
		...restProps
	}: WithElementRef<HTMLAnchorAttributes> & {
		variant?: BadgeVariant;
	} = $props();
</script>

<svelte:element
	this={href ? "a" : "span"}
	bind:this={ref}
	{href}
	class={cn(badgeVariants({ variant, className }))}
	{...restProps}
>
	{@render children?.()}
</svelte:element>
