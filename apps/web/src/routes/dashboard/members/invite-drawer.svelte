<script lang="ts">
import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
import { Button, buttonVariants } from "$lib/components/ui/button";
import { Card } from "$lib/components/ui/card";
import DatePicker from "$lib/components/ui/date-picker.svelte";
import * as Field from "$lib/components/ui/field";
import { Input } from "$lib/components/ui/input";
import PhoneInput from "$lib/components/ui/phone-input.svelte";
import { Separator } from "$lib/components/ui/separator";
import * as Sheet from "$lib/components/ui/sheet/index.js";
import { fromDate, getLocalTimeZone } from "@internationalized/date";
import dayjs from "dayjs";
import { Info, Loader, Pencil, Plus, Trash2 } from "@lucide/svelte";
import { submitBulkInvites, validateSingleInvite } from "./data.remote";
import { adminInviteRemoteSchema } from "$lib/schemas/adminInvite";

type Invite = {
	firstName: string;
	lastName: string;
	email: string;
	phoneNumber: string;
	dateOfBirth: string;
};

let invitesList = $state<Invite[]>([]);
let editingIndex = $state<number | null>(null);
let firstNameInput = $state<HTMLInputElement | null>(null);
let dialogHeading = $state<HTMLElement | null>(null);
let queueAnnouncement = $state("");

// Success/error message state
let formMessage = $state<{ success?: string; failure?: string } | null>(null);

// Date picker value for single invite form
const dobValue = $derived.by(() => {
	const dob = validateSingleInvite.fields.dateOfBirth.value();
	if (!dob || !dayjs(dob).isValid()) return undefined;
	return fromDate(dayjs(dob).toDate(), getLocalTimeZone());
});

function resetInviteForm({ focus = false } = {}) {
	validateSingleInvite.fields.set({
		firstName: "",
		lastName: "",
		email: "",
		phoneNumber: "",
		dateOfBirth: "",
	});
	editingIndex = null;
	if (focus) queueMicrotask(() => firstNameInput?.focus());
}

async function addInviteToList() {
	formMessage = null;
	await validateSingleInvite.validate({ includeUntouched: true });
	if (
		validateSingleInvite.fields.allIssues() &&
		validateSingleInvite.fields.allIssues()!.length > 0
	)
		return;

	const values = validateSingleInvite.fields.value();
	const invite: Invite = {
		firstName: values.firstName || "",
		lastName: values.lastName || "",
		email: values.email ?? "",
		phoneNumber: values.phoneNumber || "",
		dateOfBirth: values.dateOfBirth || "",
	};

	if (editingIndex === null) {
		invitesList = [...invitesList, invite];
		queueAnnouncement = `${invite.firstName} ${invite.lastName} added. ${invitesList.length} ${invitesList.length === 1 ? "invitation" : "invitations"} ready to send.`;
	} else {
		invitesList = invitesList.map((currentInvite, index) =>
			index === editingIndex ? invite : currentInvite,
		);
		queueAnnouncement = `${invite.firstName} ${invite.lastName} updated.`;
	}

	resetInviteForm({ focus: true });
}

function editInvite(index: number) {
	const invite = invitesList[index];
	if (!invite) return;

	formMessage = null;
	editingIndex = index;
	validateSingleInvite.fields.set(invite);
	queueAnnouncement = `Editing ${invite.firstName} ${invite.lastName}.`;
	queueMicrotask(() => firstNameInput?.focus());
}

function cancelEditing() {
	resetInviteForm({ focus: true });
	queueAnnouncement = "Editing cancelled.";
}

function removeInvite(index: number) {
	const invite = invitesList[index];
	if (!invite) return;

	invitesList = invitesList.filter((_, i) => i !== index);
	if (editingIndex === index) resetInviteForm();
	else if (editingIndex !== null && editingIndex > index) editingIndex -= 1;
	queueAnnouncement = `${invite.firstName} ${invite.lastName} removed. ${invitesList.length} ${invitesList.length === 1 ? "invitation" : "invitations"} ready to send.`;
}

function clearAllInvites() {
	invitesList = [];
	resetInviteForm({ focus: true });
	queueAnnouncement = "Invitation list cleared.";
}

function handleBulkSubmit() {
	const invitationCount = invitesList.length;
	submitBulkInvites({ invites: invitesList })
		.then((response) => {
			invitesList = [];
			resetInviteForm();
			queueAnnouncement = `${invitationCount} ${invitationCount === 1 ? "invitation" : "invitations"} sent for processing.`;
			formMessage = {
				success:
					response?.success ||
					"Invitations are being processed in the background. You will be notified when completed.",
			};
		})
		.catch((error) => {
			console.error("Bulk invite error:", error);
			formMessage = {
				failure: "Failed to process invitations. Please try again.",
			};
		});
}
</script>

<Sheet.Root>
	<Sheet.Trigger class={buttonVariants()}>Invite members</Sheet.Trigger>
	<Sheet.Content
		class="w-full max-w-none gap-0 overflow-hidden border-l-0 p-0 sm:w-[30rem] sm:max-w-[calc(100vw-2rem)] sm:border-l"
		side="right"
		onOpenAutoFocus={(event) => {
			event.preventDefault();
			dialogHeading?.focus();
		}}
	>
		<Sheet.Header
			class="shrink-0 border-b bg-background px-4 pt-[max(1rem,env(safe-area-inset-top))] pr-16 pb-4 sm:px-6 sm:pt-5 sm:pb-5"
		>
			<Sheet.Title bind:ref={dialogHeading} tabindex={-1}
				>Invite Members</Sheet.Title
			>
			<Sheet.Description
				>Add new members to the club by sending them invitations.
			</Sheet.Description>
		</Sheet.Header>

		<div
			class="min-h-0 flex-1 space-y-6 overflow-y-auto overscroll-contain px-4 py-5 sm:px-6"
		>
			<div class="space-y-1">
				<h3 class="font-semibold">Member details</h3>
				<p class="text-sm leading-5 text-muted-foreground">
					All fields are required. Date of birth confirms the member meets the
					club's age requirement.
				</p>
			</div>

			<form
				{...validateSingleInvite.preflight(adminInviteRemoteSchema)}
				onsubmit={(e) => {
					e.preventDefault();
					addInviteToList();
				}}
				class="space-y-5"
			>
				{#if formMessage}
					<Alert variant={formMessage.success ? "success" : "destructive"}>
						<Info class="h-4 w-4" />
						<AlertTitle>
							{formMessage.success
								? "Invitations are being processed in the background."
								: "Something went wrong"}
						</AlertTitle>
						<AlertDescription>
							{#if formMessage.success}
								Invitations are being processed in the background. You will be
								notified when completed.
							{:else}
								{formMessage.failure}
							{/if}
						</AlertDescription>
					</Alert>
				{/if}

				<Field.Group class="gap-4">
					<div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
						<Field.Field>
							{@const fieldProps =
								validateSingleInvite.fields.firstName.as("text")}
							<Field.Label for={fieldProps.name}
								>First Name <span aria-hidden="true" class="text-destructive"
									>*</span
								><span class="sr-only"> required</span></Field.Label
							>
							<Input
								{...fieldProps}
								bind:ref={firstNameInput}
								id={fieldProps.name}
								autocomplete="given-name"
								class="h-11"
							/>
							{#each validateSingleInvite.fields.firstName.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>

						<Field.Field>
							{@const fieldProps =
								validateSingleInvite.fields.lastName.as("text")}
							<Field.Label for={fieldProps.name}
								>Last Name <span aria-hidden="true" class="text-destructive"
									>*</span
								><span class="sr-only"> required</span></Field.Label
							>
							<Input
								{...fieldProps}
								id={fieldProps.name}
								autocomplete="family-name"
								class="h-11"
							/>
							{#each validateSingleInvite.fields.lastName.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
					</div>

					<Field.Field>
						{@const fieldProps = validateSingleInvite.fields.email.as("email")}
						<Field.Label for={fieldProps.name}
							>Email <span aria-hidden="true" class="text-destructive">*</span
							><span class="sr-only"> required</span></Field.Label
						>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							autocomplete="email"
							class="h-11"
						/>
						{#each validateSingleInvite.fields.email.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const { value, ...fieldProps } =
							validateSingleInvite.fields.dateOfBirth.as("text")}
						<Field.Label for={fieldProps.name}
							>Date of birth <span aria-hidden="true" class="text-destructive"
								>*</span
							><span class="sr-only"> required</span></Field.Label
						>
						<DatePicker
							{...fieldProps}
							id={fieldProps.name}
							value={dobValue}
							onDateChange={(date) => {
								if (!date) return;
								validateSingleInvite.fields.dateOfBirth.set(
									dayjs(date).format("YYYY-MM-DD"),
								);
							}}
						/>
						{#each validateSingleInvite.fields.dateOfBirth.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							validateSingleInvite.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}
							>Phone Number <span aria-hidden="true" class="text-destructive"
								>*</span
							><span class="sr-only"> required</span></Field.Label
						>
						<PhoneInput
							placeholder="Enter your phone number"
							{...fieldProps}
							id={fieldProps.name}
							onChange={(v) =>
								validateSingleInvite.fields.phoneNumber.set(String(v))}
						/>
						{#each validateSingleInvite.fields.phoneNumber.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</Field.Group>

				<div class="space-y-2 pt-1">
					<Button type="submit" class="w-full">
						<Plus class="size-4" />
						{editingIndex === null ? "Add invite" : "Update invite"}
					</Button>
					{#if editingIndex !== null}
						<Button
							type="button"
							variant="ghost"
							class="w-full"
							onclick={cancelEditing}>Cancel editing</Button
						>
					{/if}
				</div>
			</form>

			{#if invitesList.length > 0}
				<Separator />

				<section class="space-y-3" aria-labelledby="ready-to-send-heading">
					<div class="flex items-center justify-between gap-3">
						<h3 id="ready-to-send-heading" class="text-lg font-semibold">
							Ready to send ({invitesList.length})
						</h3>
						<Button variant="ghost" onclick={clearAllInvites}>Clear All</Button>
					</div>

					<ul class="space-y-3">
						{#each invitesList as invite, index (invite.email + index)}
							<li>
								<Card class="gap-3 p-4">
									<div class="flex items-start justify-between gap-3">
										<div class="min-w-0 flex-1">
											<p class="font-semibold">
												{invite.firstName}
												{invite.lastName}
											</p>
											<p class="break-all text-sm text-muted-foreground">
												{invite.email}
											</p>
											<p class="mt-1 text-xs leading-5 text-muted-foreground">
												Born {dayjs(invite.dateOfBirth).format("D MMM YYYY")}
												<span aria-hidden="true"> · </span>
												{invite.phoneNumber}
											</p>
										</div>
										<div class="flex shrink-0 gap-2">
											<Button
												variant="ghost"
												size="icon"
												onclick={() => editInvite(index)}
												aria-label={`Edit invite for ${invite.firstName} ${invite.lastName}`}
											>
												<Pencil class="size-4" />
											</Button>
											<Button
												variant="ghost"
												size="icon"
												onclick={() => removeInvite(index)}
												aria-label={`Remove invite for ${invite.firstName} ${invite.lastName}`}
											>
												<Trash2 class="size-4" />
											</Button>
										</div>
									</div>
								</Card>
							</li>
						{/each}
					</ul>
				</section>
			{/if}
		</div>

		<p class="sr-only" aria-live="polite">{queueAnnouncement}</p>

		{#if invitesList.length > 0}
			<Sheet.Footer
				class="shrink-0 border-t bg-background/95 px-4 pt-3 pb-[max(1rem,env(safe-area-inset-bottom))] backdrop-blur sm:px-6"
			>
				{#if editingIndex !== null}
					<p
						id="finish-editing-hint"
						class="text-center text-sm text-muted-foreground"
					>
						Save or cancel your edits before sending.
					</p>
				{/if}
				<Button
					type="button"
					class="w-full"
					onclick={handleBulkSubmit}
					disabled={editingIndex !== null || !!submitBulkInvites.pending}
					aria-describedby={editingIndex !== null
						? "finish-editing-hint"
						: undefined}
				>
					{#if submitBulkInvites.pending}
						<Loader class="size-4 animate-spin" />
						Sending invitations…
					{:else}
						Send {invitesList.length}
						{invitesList.length === 1 ? "invitation" : "invitations"}
					{/if}
				</Button>
			</Sheet.Footer>
		{/if}
	</Sheet.Content>
</Sheet.Root>
