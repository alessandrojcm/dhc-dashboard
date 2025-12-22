<script lang="ts">
import ConfirmInvitation from './confirm-invitation.svelte';
import PaymentForm from './payment-form.svelte';

const { data } = $props();
let isVerified = $state(data.isConfirmed);
</script>

{#if !isVerified}
	<ConfirmInvitation bind:isVerified={isVerified} />
{:else}
	<PaymentForm {...data} />
{/if}
