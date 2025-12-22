<script lang="ts">
import ConfirmInvitation from './confirm-invitation.svelte';
import PaymentForm from './payment-form.svelte';

const { data } = $props();
const _isVerified = $state(data.isConfirmed);
</script>

{#if !_isVerified}
	<ConfirmInvitation bind:isVerified={_isVerified} />
{:else}
	<PaymentForm {...data} />
{/if}
