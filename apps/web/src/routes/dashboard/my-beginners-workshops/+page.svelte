<!--
	ALE-379: "My Beginners' Workshops" — the member's upcoming and same-day
	Staff assignments, each opening its door view.
-->
<script lang="ts">
import { DoorOpen } from "@lucide/svelte";
import { resolve } from "$app/paths";
import {
	formatCivilDate,
	stageLabel,
	staffRoleLabel,
} from "#lib/beginners-workshops/presentation.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";

const { data } = $props();
</script>

<div class="mx-auto flex max-w-2xl flex-col gap-6 py-4">
	<header>
		<h1 class="font-heading text-3xl">My Beginners' Workshops</h1>
		<p class="text-sm text-muted-foreground">
			Workshops you're on the Staff of, today and coming up.
		</p>
	</header>

	{#if data.assignments.length}
		<ul class="flex flex-col gap-3">
			{#each data.assignments as assignment (assignment.id)}
				<li
					class="flex flex-wrap items-center justify-between gap-3 rounded-2xl border bg-card p-4"
					data-testid="beginners-workshop-assignment"
				>
					<div class="flex flex-col gap-1">
						<span class="font-semibold"
							>{formatCivilDate(assignment.date)} · {assignment.startTime}</span
						>
						<span class="text-sm text-muted-foreground">{assignment.venue}</span
						>
						<div class="flex flex-wrap gap-2">
							<Badge>{staffRoleLabel(assignment.role)}</Badge>
							<Badge variant="outline">{stageLabel(assignment.stage)}</Badge>
						</div>
					</div>
					<Button
						href={resolve(
							"/dashboard/beginners-workshop/workshops/[workshopId]/door",
							{ workshopId: assignment.id },
						)}
					>
						<DoorOpen /> Door view
					</Button>
				</li>
			{/each}
		</ul>
	{:else}
		<Empty.Root class="border">
			<Empty.Header>
				<Empty.Title>No workshops right now</Empty.Title>
				<Empty.Description
					>When you're added to a workshop's Staff it shows up here.</Empty.Description
				>
			</Empty.Header>
		</Empty.Root>
	{/if}
</div>
