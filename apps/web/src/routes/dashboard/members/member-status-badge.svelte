<script lang="ts">
import { Badge, type BadgeVariant } from "$lib/components/ui/badge";
import type { MemberStatus } from "./member-table.types";

type Props = {
	status: MemberStatus;
};

const { status }: Props = $props();

const statusPresentation = {
	active: {
		label: "Active",
		variant: "default",
		dotClass: "bg-primary-foreground",
	},
	paused: {
		label: "Paused",
		variant: "secondary",
		dotClass: "bg-secondary-foreground",
	},
	inactive: {
		label: "Inactive",
		variant: "destructive",
		dotClass: "bg-white",
	},
} satisfies Record<
	MemberStatus,
	{ label: string; variant: BadgeVariant; dotClass: string }
>;

const presentation = $derived(statusPresentation[status]);
</script>

<Badge variant={presentation.variant} class="gap-1.5 px-2.5 py-1">
	<span
		class={["size-1.5 rounded-full", presentation.dotClass]}
		aria-hidden="true"
	></span>
	{presentation.label}
</Badge>
