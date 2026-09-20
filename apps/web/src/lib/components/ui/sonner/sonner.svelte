<script lang="ts">
import {
	Toaster as Sonner,
	type ToasterProps as SonnerProps,
} from "svelte-sonner";
import { mode } from "mode-watcher";

let { ...restProps }: SonnerProps = $props();
</script>

<Sonner
	theme={mode.current}
	position="top-center"
	closeButton
	richColors
	expand={false}
	duration={4000}
	class="toaster group"
	style="--normal-bg: hsl(var(--popover)); --normal-text: hsl(var(--popover-foreground)); --normal-border: hsl(var(--border)); --success-bg: hsl(var(--popover)); --success-text: hsl(var(--popover-foreground)); --success-border: hsl(var(--border)); --error-bg: hsl(var(--popover)); --error-text: hsl(var(--popover-foreground)); --error-border: hsl(var(--border));"
	{...restProps}
/>
