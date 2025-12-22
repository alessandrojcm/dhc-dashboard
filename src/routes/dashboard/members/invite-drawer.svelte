<script lang="ts">
	import {
		Alert,
		AlertDescription,
		AlertTitle,
	} from "$lib/components/ui/alert";
	import { Button } from "$lib/components/ui/button";
	import { Card } from "$lib/components/ui/card";
	import DatePicker from "$lib/components/ui/date-picker.svelte";
	import * as Field from "$lib/components/ui/field";
	import { Input } from "$lib/components/ui/input";
	import PhoneInput from "$lib/components/ui/phone-input.svelte";
	import { ScrollArea } from "$lib/components/ui/scroll-area";
	import { Separator } from "$lib/components/ui/separator";
	import * as Sheet from "$lib/components/ui/sheet/index.js";
	import { fromDate, getLocalTimeZone } from "@internationalized/date";
	import dayjs from "dayjs";
	import { Info, Loader, Plus, Trash2 } from "lucide-svelte";
	import { submitBulkInvites, validateSingleInvite } from "./data.remote";
	import { adminInviteRemoteSchema } from "$lib/schemas/adminInvite";

	let isOpen = $state(false);

	// Local state for the invite list (since we're building it client-side)
	let invitesList = $state<
		Array<{
			firstName: string;
			lastName: string;
			email: string;
			phoneNumber: string;
			dateOfBirth: string;
		}>
	>([]);

	// Success/error message state
	let formMessage = $state<{ success?: string; failure?: string } | null>(
		null,
	);

	// Date picker value for single invite form
	const dobValue = $derived.by(() => {
		const dob = validateSingleInvite.fields.dateOfBirth.value();
		if (!dob || !dayjs(dob).isValid()) return undefined;
		return fromDate(dayjs(dob).toDate(), getLocalTimeZone());
	});

	// Add current invite to the list
	async function addInviteToList() {
		// Trigger validation
		validateSingleInvite.validate({ includeUntouched: true });
		if (
			validateSingleInvite.fields.allIssues() &&
			validateSingleInvite.fields.allIssues()!.length > 0
		)
			return;

		// Get values and add to list
		const values = validateSingleInvite.fields.value();
		invitesList = [
			...invitesList,
			{
				firstName: values.firstName || "",
				lastName: values.lastName || "",
				email: values.email,
				phoneNumber: values.phoneNumber || "",
				dateOfBirth: values.dateOfBirth || "",
			},
		];
		// Reset single invite form
		validateSingleInvite.fields.set({
			firstName: "",
			lastName: "",
			email: "",
			phoneNumber: "",
			dateOfBirth: "",
		});
	}

	// Remove an invite from the list
	function removeInvite(index: number) {
		invitesList = invitesList.filter((_, i) => i !== index);
	}

	// Clear all invites
	function clearAllInvites() {
		invitesList = [];
	}

	// Handle bulk form submission
	function handleBulkSubmit() {
		// Sync invites list to bulk form before submission
		submitBulkInvites({ invites: invitesList })
			.then((response) => {
				// Clear the list after successful submission
				invitesList = [];
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

<Button variant="outline" onclick={() => (isOpen = true)}>Invite Members</Button
>

<Sheet.Root bind:open={isOpen}>
	<Sheet.Content
		class="w-[400px] sm:w-[540px] p-4 scroll-smooth"
		side="right"
	>
		<Sheet.Header>
			<Sheet.Title>Invite Members</Sheet.Title>
			<Sheet.Description
				>Add new members to the club by sending them invitations.
			</Sheet.Description>
		</Sheet.Header>

		<div class="space-y-6 scroll-smooth overflow-y-scroll">
			<!-- Invite Form -->
			<form
				{...validateSingleInvite.preflight(adminInviteRemoteSchema)}
				onsubmit={(e) => {
					e.preventDefault();
					addInviteToList();
				}}
				class="space-y-4"
			>
				{#if formMessage}
					<Alert
						variant={formMessage.success
							? "success"
							: "destructive"}
					>
						<Info class="h-4 w-4" />
						<AlertTitle>
							{formMessage.success
								? "Invitations are being processed in the background."
								: "Something went wrong"}
						</AlertTitle>
						<AlertDescription>
							{#if formMessage.success}
								Invitations are being processed in the
								background. You will be notified when completed.
							{:else}
								{formMessage.failure}
							{/if}
						</AlertDescription>
					</Alert>
				{/if}

				<Field.Group>
					<div class="grid grid-cols-2 gap-4">
						<!-- First Name -->
						<Field.Field>
							{@const fieldProps =
								validateSingleInvite.fields.firstName.as(
									"text",
								)}
							<Field.Label for={fieldProps.name}
								>First Name</Field.Label
							>
							<Input {...fieldProps} id={fieldProps.name} />
							{#each validateSingleInvite.fields.firstName.issues() as issue}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>

						<!-- Last Name -->
						<Field.Field>
							{@const fieldProps =
								validateSingleInvite.fields.lastName.as("text")}
							<Field.Label for={fieldProps.name}
								>Last Name</Field.Label
							>
							<Input {...fieldProps} id={fieldProps.name} />
							{#each validateSingleInvite.fields.lastName.issues() as issue}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
					</div>

					<!-- Email -->
					<Field.Field>
						{@const fieldProps =
							validateSingleInvite.fields.email.as("email")}
						<Field.Label for={fieldProps.name}>Email</Field.Label>
						<Input {...fieldProps} id={fieldProps.name} />
						{#each validateSingleInvite.fields.email.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<!-- Date of Birth -->
					<Field.Field>
						{@const { value, ...fieldProps } =
							validateSingleInvite.fields.dateOfBirth.as("text")}
						<Field.Label for={fieldProps.name}
							>Date of birth</Field.Label
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
						{#each validateSingleInvite.fields.dateOfBirth.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<!-- Phone Number -->
					<Field.Field>
						{@const fieldProps =
							validateSingleInvite.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}
							>Phone Number</Field.Label
						>
						<PhoneInput
							placeholder="Enter your phone number"
							{...fieldProps}
							id={fieldProps.name}
							onChange={(v) =>
								validateSingleInvite.fields.phoneNumber.set(
									String(v),
								)}
						/>
						{#each validateSingleInvite.fields.phoneNumber.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</Field.Group>
			</form>

			<div class="flex justify-between gap-2">
				<Button
					type="button"
					onclick={handleBulkSubmit}
					disabled={invitesList.length === 0 ||
						!!submitBulkInvites.pending}
				>
					{#if submitBulkInvites.pending}
						<Loader class="mr-2 h-4 w-4 animate-spin" />
					{/if}
					Send {invitesList.length} Invitations
				</Button>
				<Button
					type="button"
					variant="outline"
					onclick={addInviteToList}
				>
					<Plus class="mr-2 h-4 w-4" />
					Add to List
				</Button>
			</div>

			<Separator />

			<!-- Invite List -->
			<div class="space-y-4">
				<div class="flex items-center justify-between">
					<h3 class="text-lg font-medium">
						Invite List ({invitesList.length})
					</h3>
					{#if invitesList.length > 0}
						<Button
							variant="outline"
							size="sm"
							onclick={clearAllInvites}>Clear All</Button
						>
					{/if}
				</div>

				{#if invitesList.length === 0}
					<div class="text-center py-8 text-muted-foreground">
						<p>
							No invites added yet. Add members using the form
							above.
						</p>
					</div>
				{:else}
					<ScrollArea class="h-[300px]">
						<div class="space-y-3 pr-2">
							{#each invitesList as invite, index (invite.email + index)}
								<Card class="p-3">
									<div
										class="flex justify-between items-start"
									>
										<div>
											<p class="font-medium">
												{invite.firstName}
												{invite.lastName}
											</p>
											<p
												class="text-sm text-muted-foreground"
											>
												{invite.email}
											</p>
											{#if invite.phoneNumber}
												<p
													class="text-xs text-muted-foreground"
												>
													{invite.phoneNumber}
												</p>
											{/if}
										</div>
										<Button
											variant="ghost"
											size="icon"
											class="h-8 w-8"
											onclick={() => removeInvite(index)}
											aria-label="Remove invite"
										>
											<Trash2 class="h-4 w-4" />
										</Button>
									</div>
								</Card>
							{/each}
						</div>
					</ScrollArea>
				{/if}
			</div>
		</div>
	</Sheet.Content>
</Sheet.Root>
