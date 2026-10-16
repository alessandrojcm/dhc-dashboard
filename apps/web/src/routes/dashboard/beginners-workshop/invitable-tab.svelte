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
import {
	ArrowUpRight,
	Check,
	Clock,
	MailPlus,
	Search,
	UsersRound,
	X,
} from "@lucide/svelte";
import { followUpLabel, personName } from "#lib/beginners-workshops/console.js";
import { formatCivilDate } from "#lib/club-calendar.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import InviteButton from "./invite-button.svelte";

let { people }: { people: BeginnersWorkshopInvitable[] } = $props();
let search = $state("");
const filteredPeople = $derived(
	people.filter((person) =>
		`${personName(person)} ${person.email}`
			.toLowerCase()
			.includes(search.trim().toLowerCase()),
	),
);
</script>

{#snippet identity(person: BeginnersWorkshopInvitable)}
	<div class="flex min-w-0 items-center gap-3">
		<div
			class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary"
			aria-hidden="true"
		>
			{personName(person)
				.split(/\s+/)
				.slice(0, 2)
				.map((part) => part.slice(0, 1))
				.join("")}
		</div>
		<div class="min-w-0">
			<p class="break-words font-semibold text-foreground">
				{personName(person)}
			</p>
			<a
				href={`mailto:${person.email}`}
				class="block break-all text-sm text-muted-foreground underline-offset-4 hover:text-primary hover:underline"
				>{person.email}</a
			>
		</div>
	</div>
{/snippet}

{#snippet followUp(person: BeginnersWorkshopInvitable)}
	<Badge
		variant="outline"
		class="gap-1.5 whitespace-normal border-border bg-muted/30 text-foreground"
	>
		{#if person.followUp.status === "sent"}<Check
				class="size-3.5 text-primary"
				aria-hidden="true"
			/>{:else}<Clock
				class="size-3.5 text-muted-foreground"
				aria-hidden="true"
			/>{/if}
		{followUpLabel(person.followUp)}
	</Badge>
{/snippet}

{#snippet workshopLink(person: BeginnersWorkshopInvitable)}
	<a
		class="inline-flex items-center gap-1.5 text-sm font-medium text-primary underline-offset-4 hover:underline"
		href={resolve("/dashboard/beginners-workshop/workshops/[workshopId]", {
			workshopId: person.workshopId,
		})}
		>{formatCivilDate(person.workshopDate)}<ArrowUpRight
			class="size-3.5"
			aria-hidden="true"
		/></a
	>
{/snippet}

{#snippet emptyState()}
	<Empty.Root class="min-h-64">
		<Empty.Header>
			<Empty.Media variant="icon"><UsersRound /></Empty.Media>
			<Empty.Title
				>{people.length
					? "No matching attendees"
					: "Nobody to invite"}</Empty.Title
			>
			<Empty.Description
				>{people.length
					? "Try a different name or email address."
					: "People appear here after they attend a workshop and staff confirm attendance."}</Empty.Description
			>
		</Empty.Header>
		{#if search}<Empty.Content
				><Button variant="outline" onclick={() => (search = "")}
					>Clear search</Button
				></Empty.Content
			>{/if}
	</Empty.Root>
{/snippet}

<section
	aria-labelledby="invitable-title"
	class="flex flex-col overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)] lg:h-full lg:min-h-0"
>
	<header class="shrink-0 border-b border-border bg-muted/20 p-4 sm:p-5">
		<div class="flex flex-wrap items-start justify-between gap-4">
			<div class="flex items-start gap-3">
				<div
					class="hidden size-12 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary sm:flex"
				>
					<MailPlus class="size-6" aria-hidden="true" />
				</div>
				<div>
					<div class="flex flex-wrap items-center gap-3">
						<h2 id="invitable-title" class="font-heading text-2xl">
							Ready to invite
						</h2>
						<Badge variant="secondary"
							>{people.length}
							{people.length === 1 ? "person" : "people"}</Badge
						>
					</div>
					<p class="mt-1 max-w-2xl text-sm leading-6 text-muted-foreground">
						Workshop attendees ready for their membership invitation. You can
						invite them before the follow-up email is sent.
					</p>
				</div>
			</div>
			<Button variant="outline" href={resolve("/dashboard/members/invitations")}
				>Manage invitations<ArrowUpRight aria-hidden="true" /></Button
			>
		</div>
		<div class="mt-4 flex flex-wrap items-center justify-between gap-4">
			<div class="grid w-full gap-2 sm:max-w-md">
				<Label for="invitable-search">Search attendees</Label>
				<div class="relative">
					<Search
						class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
						aria-hidden="true"
					/><Input
						id="invitable-search"
						type="search"
						placeholder="Name or email address"
						bind:value={search}
						class="h-11 pl-10 pr-11"
					/>{#if search}<Button
							variant="ghost"
							size="icon"
							class="absolute right-0 top-0"
							aria-label="Clear search"
							onclick={() => (search = "")}><X aria-hidden="true" /></Button
						>{/if}
				</div>
			</div>
			<p class="max-w-sm text-sm leading-5 text-muted-foreground">
				<span class="font-semibold text-foreground"
					>Standard membership · invitation valid for 7 days</span
				><br />Each Invite button sends one invitation email.
			</p>
		</div>
	</header>
	<div
		class="lg:min-h-0 lg:flex-1 lg:overflow-y-auto"
		role="region"
		aria-label="Attendees ready to invite"
	>
		{#if filteredPeople.length}
			<div>
				<Table.Root class="block lg:table">
					<Table.Caption class="sr-only"
						>Attendees ready for a membership invitation, with workshop
						attendance and follow-up status.</Table.Caption
					>
					<Table.Header class="hidden bg-muted/50 lg:table-header-group">
						<Table.Row class="hover:bg-transparent">
							<Table.Head
								scope="col"
								class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
								>Attendee</Table.Head
							>
							<Table.Head
								scope="col"
								class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
								>Workshop attended</Table.Head
							>
							<Table.Head
								scope="col"
								class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
								>Follow-up email</Table.Head
							>
							<Table.Head
								scope="col"
								class="px-4 text-right text-xs font-bold uppercase tracking-wide text-muted-foreground"
								>Invitation</Table.Head
							>
						</Table.Row>
					</Table.Header>
					<Table.Body class="block lg:table-row-group">
						{#each filteredPeople as person (person.intakeId)}
							<Table.Row
								data-testid="invitable-row"
								class="block p-4 hover:bg-transparent sm:p-5 lg:table-row lg:p-0 lg:hover:bg-muted/50"
							>
								<Table.Cell class="block pb-4 lg:table-cell lg:px-4 lg:py-4"
									>{@render identity(person)}</Table.Cell
								>
								<Table.Cell
									class="block rounded-t-xl bg-muted/30 px-3 pt-3 pb-2 lg:table-cell lg:rounded-none lg:bg-transparent lg:px-4 lg:py-4"
								>
									<span
										class="mb-1 block text-xs font-bold uppercase tracking-wide text-muted-foreground lg:hidden"
										>Workshop attended</span
									>
									{@render workshopLink(person)}
								</Table.Cell>
								<Table.Cell
									class="block rounded-b-xl bg-muted/30 px-3 pt-2 pb-3 lg:table-cell lg:rounded-none lg:bg-transparent lg:px-4 lg:py-4"
								>
									<span
										class="mb-1 block text-xs font-bold uppercase tracking-wide text-muted-foreground lg:hidden"
										>Follow-up email</span
									>
									{@render followUp(person)}
								</Table.Cell>
								<Table.Cell
									class="block pt-4 text-right lg:table-cell lg:px-4 lg:py-4"
								>
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
			{@render emptyState()}
		{/if}
	</div>
	<footer
		class="shrink-0 border-t border-border bg-muted/20 px-4 py-3 text-sm text-muted-foreground sm:px-5"
	>
		{#if search}{filteredPeople.length} of {people.length} attendees{:else}{people.length}
			{people.length === 1 ? "attendee" : "attendees"} ready{/if}<span
			class="hidden sm:inline"
		>
			· Invited people leave this list. Resend or delete from Members →
			Invitations.</span
		>
	</footer>
</section>
