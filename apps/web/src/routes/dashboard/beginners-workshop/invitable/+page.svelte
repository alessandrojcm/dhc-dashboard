<script lang="ts">
import type { PageProps } from "./$types";
import InvitableTab from "../invitable-tab.svelte";
let { data }: PageProps = $props();
</script>

<InvitableTab people={data.invitable} />
