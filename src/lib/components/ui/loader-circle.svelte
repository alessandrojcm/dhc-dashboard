<script lang="ts">
    import { LoaderCircle } from "lucide-svelte";

    const { class: className }: { class?: string } = $props();
</script>

<LoaderCircle class="animate-spin text:currentColor {className}" />
