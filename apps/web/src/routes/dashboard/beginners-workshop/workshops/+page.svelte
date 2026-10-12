<script lang="ts">
import type { PageProps } from "./$types";
import WorkshopsTab from "../workshops-tab.svelte";
let { data }: PageProps = $props();
</script>

<WorkshopsTab workshops={data.workshops} candidates={data.staffCandidates} />
