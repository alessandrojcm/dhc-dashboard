<!--
	ALE-392: the Invitable view — everyone whose standing is `attended`,
	across workshops, with the workshop date and the Follow-up's status. One
	click per person sends the standard Invitation; a refusal stays on the
	row. A person leaves once invited and comes back if that Invitation is
	deleted. Resend and delete live in Members → Invitations.
-->
<script lang="ts">
import type { BeginnersWorkshopInvitable } from "@dhc/api-client";
import { resolve } from "$app/paths";
import { followUpLabel, personName } from "#lib/beginners-workshops/console.js";
import { formatCivilDate } from "#lib/beginners-workshops/presentation.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import InviteButton from "./invite-button.svelte";

let { people }: { people: BeginnersWorkshopInvitable[] } = $props();
</script>

<div class="flex flex-col gap-4 py-4">
	<p class="max-w-3xl text-sm text-muted-foreground">
		Attended a Beginners' Workshop, no Invitation yet. Inviting doesn't wait for
		the follow-up email. The Invitation is the standard tier with a 7-day
		expiry; resend and delete it from Members → Invitations.
	</p>

	{#if people.length}
		<div class="rounded-xl border bg-card">
			<Table.Root>
				<Table.Header>
					<Table.Row>
						<Table.Head>Name</Table.Head>
						<Table.Head>Attended</Table.Head>
						<Table.Head class="hidden md:table-cell">Follow-up</Table.Head>
						<Table.Head class="text-right"
							><span class="sr-only">Invite</span></Table.Head
						>
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{#each people as person (person.intakeId)}
						<Table.Row data-testid="invitable-row">
							<Table.Cell>
								<span class="font-medium">{personName(person)}</span>
								<span class="block text-xs text-muted-foreground"
									>{person.email}</span
								>
							</Table.Cell>
							<Table.Cell>
								<a
									class="underline-offset-2 hover:underline"
									href={resolve(
										"/dashboard/beginners-workshop/workshops/[workshopId]",
										{ workshopId: person.workshopId },
									)}>{formatCivilDate(person.workshopDate)}</a
								>
							</Table.Cell>
							<Table.Cell
								class="hidden text-sm text-muted-foreground md:table-cell"
								>{followUpLabel(person.followUp)}</Table.Cell
							>
							<Table.Cell class="text-right">
								<InviteButton
									workshopId={person.workshopId}
									intakeId={person.intakeId}
									name={personName(person)}
								/>
							</Table.Cell>
						</Table.Row>
					{/each}
				</Table.Body>
			</Table.Root>
		</div>
	{:else}
		<Empty.Root class="border">
			<Empty.Header>
				<Empty.Title>Nobody to invite</Empty.Title>
				<Empty.Description
					>People appear here once a workshop's attendance is final.</Empty.Description
				>
			</Empty.Header>
		</Empty.Root>
	{/if}
</div>
