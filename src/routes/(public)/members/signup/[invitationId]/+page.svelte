<script lang="ts">
const { data } = $props();
const _isVerified = $state(data.isConfirmed);
</script>

{#if !isVerified}
	<ConfirmInvitation bind:isVerified />
{:else}
	<PaymentForm {...data} />
{/if}
