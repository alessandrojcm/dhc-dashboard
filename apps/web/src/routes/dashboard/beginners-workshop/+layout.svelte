<script lang="ts">
import { page } from "$app/state";
import { isBeginnersWorkshopSection } from "#lib/beginners-workshops/sections.js";
import SectionShell from "./section-shell.svelte";
import type { LayoutProps } from "./$types";

let { children, data }: LayoutProps = $props();
const isSection = $derived(isBeginnersWorkshopSection(page.route.id));
</script>

<svelte:head><title>Beginners' Workshops | Dublin HEMA Club</title></svelte:head
>

{#if isSection}
	<SectionShell {data} pathname={page.url.pathname} {children} />
{:else}
	<div class="h-full min-h-0 overflow-y-auto px-4 pb-8 sm:px-6 lg:px-8">
		{@render children()}
	</div>
{/if}
