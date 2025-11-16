<script lang="ts">
const { class: className }: { class?: string } = $props();
</script>

<LoaderCircle class="animate-spin text:currentColor {className}" />
