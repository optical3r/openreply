# Free hosting: Vercel + Supabase + Redis Cloud + Oracle VM

A zero-cost alternative to the Railway setup in [setup.md](setup.md). Each piece runs on a free tier:

| Piece | Service | Notes |
| --- | --- | --- |
| Web app | Vercel Hobby | As in setup.md. |
| PostgreSQL | Supabase Free | Always on; pauses only after 7 days with no activity, which the worker prevents. |
| Redis | Redis Cloud Free (30 MB) | No monthly command cap. Upstash Free has one, and an idle BullMQ worker uses it up. |
| Worker | Oracle Cloud Always Free VM | Runs `npm run worker` under systemd. |

Put Supabase and Redis Cloud in AWS `us-east-1`, near Vercel's default `iad1` region.

## 1. Supabase

1. Create a project in `us-east-1`.
2. **Turn off the Data API** (Project Settings, Data API), or remove `public` from its exposed schemas. Prisma creates its tables in `public` without row-level security. With the Data API on, the public anon key can read them, including sessions and encrypted tokens.
3. Open Connect and copy two connection strings:
   - **Transaction pooler**, port `6543`. Use it for `DATABASE_URL` on Vercel.
   - **Session pooler**, port `5432`. Use it for `DIRECT_URL` on Vercel, for `DATABASE_URL` on the worker, and for running migrations.

   The direct `db.<ref>.supabase.co` host is IPv6-only, so use the poolers.

Migrations read `DIRECT_URL` when it is set ([prisma.config.ts](../prisma.config.ts)). They take an advisory lock that the transaction pooler cannot hold.

If `pg` rejects the TLS certificate (`self-signed certificate in certificate chain`), append `?sslmode=no-verify` to the Supabase URLs.

## 2. Redis Cloud

1. Create a Free database on AWS `us-east-1`.
2. Set the eviction policy to **`noeviction`**. BullMQ requires it; an evicted queue key loses jobs.
3. Copy the URL: `redis://default:PASSWORD@HOST:PORT`.

## 3. Migrate

```bash
DIRECT_URL="postgresql://...pooler.supabase.com:5432/postgres" npm run db:migrate
```

## 4. Vercel

Set `DATABASE_URL` (transaction pooler), `DIRECT_URL` (session pooler), and `REDIS_URL`. Keep the other variables from setup.md. Then redeploy.

## 5. Oracle VM worker

1. Create an Always Free Ubuntu instance. Use Ampere A1 if there is capacity; otherwise use AMD E2.1.Micro.
2. SSH in and run the setup script:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/<owner>/openreply/main/scripts/oracle-worker-setup.sh \
     | sudo REPO_URL=https://github.com/<owner>/openreply.git bash
   ```

3. Fill in `/etc/openreply-worker.env` with `NEXTAUTH_URL`, `NEXTAUTH_SECRET`, `ENCRYPTION_KEY` (identical to Vercel), `DATABASE_URL` (session pooler) and `REDIS_URL`. Then run `sudo systemctl restart openreply-worker`.
4. Check it with `journalctl -u openreply-worker -f`. You should see `[DM Worker] Started`, and `/api/health` should report `worker.healthy: true`.

To update the worker, re-run the same script.

The worker only makes outbound connections, so it needs no inbound firewall rules.
