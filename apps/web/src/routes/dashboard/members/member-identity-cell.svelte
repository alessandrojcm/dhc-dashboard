<script lang="ts">
import type { Member } from "@dhc/api-client";

type Props = {
	member: Pick<Member, "firstName" | "lastName" | "email">;
};

const { member }: Props = $props();

const fullName = $derived(`${member.firstName} ${member.lastName}`.trim());
const initials = $derived(
	`${member.firstName.at(0) ?? ""}${member.lastName.at(0) ?? ""}`.toUpperCase(),
);
</script>

<div class="flex min-w-0 items-center gap-3">
	<div
		class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary"
		aria-hidden="true"
	>
		{initials}
	</div>
	<div class="min-w-0">
		<p class="font-semibold leading-5 text-foreground">{fullName}</p>
		<a
			href={`mailto:${member.email}`}
			class="block max-w-full break-all text-sm leading-5 text-muted-foreground underline-offset-4 transition-colors duration-200 hover:text-primary hover:underline focus-visible:rounded-sm focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
		>
			{member.email}
		</a>
	</div>
</div>
