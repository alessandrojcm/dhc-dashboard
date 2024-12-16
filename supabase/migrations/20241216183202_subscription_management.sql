create extension if not exists wrappers with schema extensions;
create foreign data wrapper stripe_wrapper handler stripe_fdw_handler validator stripe_fdw_validator;
-- Create schema for stripe related objects
create schema if not exists stripe;
-- Save your Stripe API key in Vault
do $$
declare api_key_id uuid;
begin -- Try to get existing key_id or insert new one
select key_id into api_key_id
from vault.secrets
where name = 'stripe';
if api_key_id is null then
insert into vault.secrets (name, secret)
values (
        'stripe',
        'rk_test_51GRuLSJ97nZndoApXRfqODO0NwZUG889EyexxoS2lV26VfPsIceZlWNkPqmrceR61oq9z6G8Hcta6EFwjWEELehX00dTjK3X1Y'
    )
returning key_id into api_key_id;
end if;
-- Create the foreign server using the api_key_id
execute format(
    'create server if not exists stripe_server 
        foreign data wrapper stripe_wrapper 
        options (
            api_key_id %L,
            api_url %L,
            api_version %L
        )',
    api_key_id,
    'https://api.stripe.com/v1/',
    '2024-11-20.acacia'
);
end $$;
create foreign table stripe.subscriptions (
    id text,
    customer text,
    currency text,
    current_period_start timestamp,
    current_period_end timestamp,
    attrs jsonb
) server stripe_server options (
    object 'subscriptions',
    rowid_column 'id'
);
create foreign table stripe.customers (
    id text,
    email text,
    name text,
    description text,
    created timestamp,
    attrs jsonb
) server stripe_server options (object 'customers', rowid_column 'id');
create foreign table stripe.products (
    id text,
    name text,
    active bool,
    default_price text,
    description text,
    created timestamp,
    updated timestamp,
    attrs jsonb
) server stripe_server options (object 'products', rowid_column 'id');
create foreign table stripe.prices (
    id text,
    active bool,
    currency text,
    product text,
    unit_amount bigint,
    type text,
    created timestamp,
    attrs jsonb
) server stripe_server options (object 'prices');
create foreign table stripe.payment_intents (
    id text,
    customer text,
    amount bigint,
    currency text,
    payment_method text,
    created timestamp,
    attrs jsonb
) server stripe_server options (object 'payment_intents');