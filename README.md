# sv

Everything you need to build a Svelte project, powered by [`sv`](https://github.com/sveltejs/cli).

## Creating a project

If you're seeing this, you've probably already done this step. Congrats!

```bash
# create a new project in the current directory
npx sv create

# create a new project in my-app
npx sv create my-app
```

## Developing

Once you've created a project and installed dependencies with `npm install` (or `pnpm install` or `yarn`), start a development server:

```bash
npm run dev

# or start the server and open the app in a new browser tab
npm run dev -- --open
```

## Building

To create a production version of your app:

```bash
npm run build
```

You can preview the production build with `npm run preview`.

## Environment Variables

To run this project, you need to configure the following environment variables:

### SvelteKit (Frontend)
- `SENTRY_AUTH_TOKEN`: Auth token for Sentry error tracking (enables Sentry integration on the server).
- `VITE_PUBLIC_SENTRY_ENABLED`: Set to `'true'` to enable Sentry error tracking in the client app.
- `PUBLIC_SUPABASE_URL`: The public URL of your Supabase project (used to connect the frontend to your Supabase backend).
- `PUBLIC_SUPABASE_ANON_KEY`: The public anonymous key for your Supabase project (used for client-side access to Supabase).
- `PUBLIC_SITE_URL`: The public URL of your deployed site (used for redirects, emails, etc.).
- `STRIPE_SECRET_KEY`: Secret API key for Stripe, used to authenticate server-side Stripe API requests.


Set these in your `.env` or `.env.local` file at the project root. Variables prefixed with `PUBLIC_` are exposed to the client.

### Supabase Functions (Deno)
- `STRIPE_SECRET_KEY`: Secret API key for Stripe, used to authenticate server-side Stripe API requests.
- `STRIPE_WEBHOOK_SIGNING_SECRET`: Secret used to verify incoming Stripe webhook signatures.
- `SENTRY_DSN`: Data Source Name for Sentry, used to report errors from Deno functions.
- `ENVIRONMENT`: The environment name (e.g., `development`, `production`) for error reporting and logging.
- `MEMBERSHIP_FEE_LOOKUP_NAME`: Stripe price lookup key for the standard membership fee.
- `ANNUAL_FEE_LOOKUP`: Stripe price lookup key for the annual membership fee.
- `SUPABASE_URL`: The URL of your Supabase project (used for server-side access in functions).
- `SUPABASE_ANON_KEY`: The public anonymous key for Supabase (sometimes needed for server-side operations).
- `SUPABASE_SERVICE_ROLE_KEY`: Supabase service role key (provides elevated privileges for backend operations).
- `POSTGRES_CONNECTION_STRING`: Connection string for your project's Postgres database (used by Deno functions for direct DB access).
- `INVITE_MEMBER_TRANSACTIONAL_ID`: Edge function env, the invite member Loops transactional ID
- `LOOPS_API_KEY`: Loops API key

Supabase vault items:
- `project_url`: The URL of your Supabase project (used for server-side access in functions).
- `service_role_key`: Supabase service role key (provides elevated privileges for backend operations).

These must be configured in your Supabase project's function environment or set in the deployment environment for Deno functions.


> To deploy your app, you may need to install an [adapter](https://svelte.dev/docs/kit/adapters) for your target environment.
