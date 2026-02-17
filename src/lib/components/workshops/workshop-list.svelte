<script lang="ts">
import { Badge } from "$lib/components/ui/badge";
import {
	Card,
	CardContent,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Button, buttonVariants } from "$lib/components/ui/button/index.js";
import * as Dialog from "$lib/components/ui/dialog/index.js";
import WorkshopExpressCheckout from "./workshop-express-checkout.svelte";
import WorkshopCancellationDialog from "./workshop-cancellation-dialog.svelte";
import dayjs from "dayjs";
import Dinero from "dinero.js";
import { useQueryClient } from "@tanstack/svelte-query";
import type { ClubActivityWithInterest, UserData } from "$lib/types";

interface Props {
	workshops: ClubActivityWithInterest[];
	onInterestToggle?: (workshopId: string) => void;
	isLoading?: boolean;
	userId: string;
}

let {
	workshops,
	onInterestToggle,
	isLoading = false,
	userId,
}: Props = $props();

let selectedWorkshop: ClubActivityWithInterest | null = $state(null);
let showCancellationDialog = $state(false);
let selectedRegistration: { id: string; status: string } | null = $state(null);
const queryClient = useQueryClient();

const userData = queryClient.getQueryData(["logged_in_user_data"]) as
	| UserData
	| undefined;

function getStatusColor(status: string = "planned") {
	switch (status) {
		case "planned":
			return "bg-yellow-500";
		case "published":
			return "bg-green-500";
		case "finished":
			return "bg-blue-500";
		case "cancelled":
			return "bg-red-500";
		default:
			return "bg-gray-500";
	}
}

function formatDateTime(dateString: string) {
	return dayjs(dateString).format("MMM D, YYYY h:mm A");
}

function formatPrice(price: number) {
	return Dinero({ amount: price, currency: "EUR" }).toFormat();
}

function hasUserInterest(workshop: ClubActivityWithInterest): boolean {
	if (workshop.status === "published") {
		return (
			workshop?.attendee_count?.some((i) => i.member_user_id === userId) ??
			false
		);
	}
	return (
		workshop?.user_interest?.map((i) => i.user_id).includes(userId) ?? false
	);
}

function getUserRegistration(
	workshop: ClubActivityWithInterest,
): { id: string; status: string } | null {
	if (workshop.status === "published") {
		const registration = workshop?.attendee_count?.find(
			(i) => i.member_user_id === userId,
		);
		return registration
			? { id: registration.id, status: registration.status }
			: null;
	}
	return null;
}

function getInterestCount(workshop: ClubActivityWithInterest): number {
	return workshop.status === "published"
		? (workshop.attendee_count?.length ?? 0)
		: (workshop.interest_count?.[0]?.interest_count ?? 0);
}

function getWorkshopPrice(workshop: ClubActivityWithInterest): number {
	// For now, assume all users are members - you can enhance this logic
	return workshop.price_member;
}

function isRefunded(workshop: ClubActivityWithInterest): boolean {
	return (
		workshop.attendee_count?.some(
			(i) => i.status === "refunded" && i.member_user_id === userId,
		) ?? false
	);
}

function handleCancelRegistration(workshop: ClubActivityWithInterest) {
	const registration = getUserRegistration(workshop);
	if (registration) {
		selectedWorkshop = workshop;
		selectedRegistration = registration;
		showCancellationDialog = true;
	}
}

function handleRegistrationSuccess() {
	queryClient.invalidateQueries({ queryKey: ["workshops"] });
}
</script>

<div class="space-y-4">
	{#if workshops.length === 0}
		<Card>
			<CardContent class="pt-6">
				<div class="text-center text-muted-foreground">
					No workshops found. Create your first workshop to get started.
				</div>
			</CardContent>
		</Card>
	{:else}
		{#each workshops as workshop (workshop.id)}
			<Card>
				<CardHeader>
					<div class="flex justify-between items-start">
						<CardTitle>{workshop.title}</CardTitle>
						{#if isRefunded(workshop)}
							<Badge class={`${getStatusColor('cancelled')} capitalize`}>Refunded</Badge>
						{:else}
							<Badge class={`${getStatusColor(workshop.status ?? 'planned')} capitalize`}>
								{workshop?.status}
							</Badge>
						{/if}
					</div>
				</CardHeader>
				<CardContent>
					<div class="space-y-2">
						{#if workshop.description}
							<p class="text-sm text-muted-foreground">{workshop.description}</p>
						{/if}
						<div class="grid grid-cols-2 gap-4 text-sm">
							<div>
								<strong>Start:</strong>
								{formatDateTime(workshop.start_date)}
							</div>
							<div>
								<strong>End:</strong>
								{formatDateTime(workshop.end_date)}
							</div>
							<div>
								<strong>Location:</strong>
								{workshop.location}
							</div>
							<div>
								<strong>Capacity:</strong>
								{workshop.max_capacity}
							</div>
							<div>
								<strong>Member Price:</strong>
								{formatPrice(workshop.price_member)}
							</div>
							{#if workshop.is_public}
								<div>
									<strong>Non-Member Price:</strong>
									{formatPrice(workshop.price_non_member)}
								</div>
							{/if}
							{#if workshop.status === 'planned'}
								<div>
									<strong>Interest:</strong>
									{getInterestCount(workshop)} people interested
								</div>
							{/if}
							{#if workshop.status === 'published'}
								<div>
									<strong>Attendees:</strong>
									{getInterestCount(workshop)} people attending
								</div>
							{/if}
						</div>
						{#if workshop.status === 'published' && userId}
							<div class="flex justify-end pt-4">
								{#if !hasUserInterest(workshop)}
									<Dialog.Root>
										<Dialog.Trigger
											onclick={() => (selectedWorkshop = workshop)}
											class={buttonVariants({ variant: 'default' })}
										>
											Register
										</Dialog.Trigger>
										<Dialog.Content>
											{#if selectedWorkshop !== null}
												<Dialog.Header>
													<Dialog.Title>Workshop Registration</Dialog.Title>
													<Dialog.Description>
														Complete your registration for {selectedWorkshop.title}
													</Dialog.Description>
												</Dialog.Header>

												<WorkshopExpressCheckout
													workshopId={selectedWorkshop.id}
													workshopTitle={selectedWorkshop.title}
													amount={getWorkshopPrice(selectedWorkshop)}
													customerId={userData?.customerId}
													onSuccess={() => {
														selectedWorkshop = null;
														handleRegistrationSuccess();
													}}
													onCancel={() => (selectedWorkshop = null)}
												/>
											{/if}
										</Dialog.Content>
									</Dialog.Root>
								{:else if !isRefunded(workshop)}
									<Button variant="destructive" onclick={() => handleCancelRegistration(workshop)}>
										Cancel Registration
									</Button>
								{/if}
							</div>
						{/if}
						{#if workshop.status === 'planned' && onInterestToggle}
							<div class="flex justify-end pt-4">
								<Button
									variant={hasUserInterest(workshop) ? 'default' : 'outline'}
									onclick={() => onInterestToggle(workshop.id)}
									disabled={isLoading}
								>
									{hasUserInterest(workshop) ? 'Withdraw Interest' : 'Express Interest'}
								</Button>
							</div>
						{/if}
					</div>
				</CardContent>
			</Card>
		{/each}
	{/if}
</div>

{#if selectedWorkshop && selectedRegistration}
	<WorkshopCancellationDialog
		workshop={selectedWorkshop}
		registrationId={selectedRegistration.id}
		registrationStatus={selectedRegistration.status}
		open={showCancellationDialog}
		onOpenChange={(open) => {
			showCancellationDialog = open;
			if (!open) {
				selectedWorkshop = null;
				selectedRegistration = null;
			}
		}}
		onSuccess={handleRegistrationSuccess}
	/>
{/if}
