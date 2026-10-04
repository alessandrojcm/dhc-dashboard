<script lang="ts">
import { Megaphone } from "@lucide/svelte";
import AnnouncementsRail from "$lib/components/training-announcements/AnnouncementsRail.svelte";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();
</script>

<svelte:head>
	<title>Training Announcements | Dublin HEMA Club</title>
</svelte:head>

<div class="mx-auto w-full max-w-5xl space-y-6 px-4 py-6 sm:px-6 sm:py-8">
	<header class="border-b border-border/80 pb-5">
		<div class="flex items-start gap-4">
			<div
				class="hidden size-12 shrink-0 place-items-center rounded-2xl border border-primary/15 bg-primary/10 text-primary sm:grid"
				aria-hidden="true"
			>
				<Megaphone class="size-6" />
			</div>
			<div class="min-w-0">
				<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
					Committee
				</p>
				<h1 class="font-heading text-3xl leading-tight font-bold sm:text-4xl">
					Training Announcements
				</h1>
				<p
					class="mt-2 max-w-2xl text-sm leading-relaxed text-muted-foreground sm:text-base"
				>
					Every Discord post the club schedules about training: the weekly roll
					call and sparring calls, and one-offs for a special session. The
					calendar of upcoming and past occurrences lands here next.
				</p>
			</div>
		</div>
	</header>

	<AnnouncementsRail today={data.today} />
</div>
