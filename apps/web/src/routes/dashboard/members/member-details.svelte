<script lang="ts">
import dayjs from "dayjs";
import MemberStatusBadge from "./member-status-badge.svelte";
import type { MemberTableRow, SocialMediaConsent } from "./member-table.types";
import MemberWeapons from "./member-weapons.svelte";

type Props = {
	member: MemberTableRow;
};

const { member }: Props = $props();

function display(value: string | null): string {
	return value?.trim() || "Not provided";
}

function formatDate(value: string | null, fallback = "Not recorded"): string {
	return value && dayjs(value).isValid()
		? dayjs(value).format("D MMM YYYY")
		: fallback;
}

function formatConsent(consent: SocialMediaConsent): string {
	const labels = {
		no: "No consent",
		yes_recognizable: "Yes, recognizable",
		yes_unrecognizable: "Yes, unrecognizable",
	} satisfies Record<SocialMediaConsent, string>;
	return labels[consent];
}

const guardianName = $derived(
	`${member.guardian_first_name ?? ""} ${member.guardian_last_name ?? ""}`.trim() ||
		"Not provided",
);
</script>

<div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
	<section class="rounded-xl border border-border/70 bg-background/70 p-4">
		<h3 class="text-sm font-bold text-foreground">Profile</h3>
		<dl class="mt-3 space-y-3">
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Age
				</dt>
				<dd class="mt-1 text-sm text-foreground">
					{member.age ?? "Not provided"}
				</dd>
			</div>
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Gender
				</dt>
				<dd class="mt-1 text-sm text-foreground">{display(member.gender)}</dd>
			</div>
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Pronouns
				</dt>
				<dd class="mt-1 text-sm text-foreground">{display(member.pronouns)}</dd>
			</div>
		</dl>
	</section>

	<section class="rounded-xl border border-border/70 bg-background/70 p-4">
		<h3 class="text-sm font-bold text-foreground">Membership</h3>
		<dl class="mt-3 space-y-3">
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Status
				</dt>
				<dd class="mt-1 flex flex-wrap items-center gap-2">
					<MemberStatusBadge status={member.membership_status} />
					{#if member.membership_status === "paused" && member.subscription_paused_until}
						<span class="text-xs text-muted-foreground">
							until {formatDate(member.subscription_paused_until)}
						</span>
					{/if}
				</dd>
			</div>
			<div class="grid grid-cols-2 gap-3">
				<div>
					<dt
						class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
					>
						Member since
					</dt>
					<dd class="mt-1 text-sm tabular-nums text-foreground">
						{formatDate(member.membership_start_date, "Never")}
					</dd>
				</div>
				<div>
					<dt
						class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
					>
						Last payment
					</dt>
					<dd class="mt-1 text-sm tabular-nums text-foreground">
						{formatDate(member.last_payment_date, "Never")}
					</dd>
				</div>
			</div>
		</dl>
	</section>

	<section class="rounded-xl border border-border/70 bg-background/70 p-4">
		<h3 class="text-sm font-bold text-foreground">Club preferences</h3>
		<dl class="mt-3 space-y-3">
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Weapons
				</dt>
				<dd class="mt-1">
					<MemberWeapons weapons={member.preferred_weapon} limit={4} />
				</dd>
			</div>
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Social media
				</dt>
				<dd class="mt-1 text-sm text-foreground">
					{formatConsent(member.social_media_consent)}
				</dd>
			</div>
		</dl>
	</section>

	<section class="rounded-xl border border-border/70 bg-background/70 p-4">
		<h3 class="text-sm font-bold text-foreground">Emergency & care</h3>
		<dl class="mt-3 space-y-3">
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Next of kin
				</dt>
				<dd class="mt-1 text-sm text-foreground">
					{display(member.next_of_kin_name)}
					{#if member.next_of_kin_phone}
						<span class="block text-muted-foreground"
							>{member.next_of_kin_phone}</span
						>
					{/if}
				</dd>
			</div>
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Guardian
				</dt>
				<dd class="mt-1 text-sm text-foreground">
					{guardianName}
					{#if member.guardian_phone_number}
						<span class="block text-muted-foreground">
							{member.guardian_phone_number}
						</span>
					{/if}
				</dd>
			</div>
			<div>
				<dt
					class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
				>
					Medical notes
				</dt>
				<dd class="mt-1 whitespace-pre-wrap text-sm text-foreground">
					{member.medical_conditions?.trim() || "None reported"}
				</dd>
			</div>
		</dl>
	</section>
</div>
