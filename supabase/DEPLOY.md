# Deploying AstroSharper's Supabase pieces

**Where this lives:** the AstroSharper repo's `supabase/` directory is the canonical home for AstroSharper's schema migrations + edge functions. AstroBlink's repo is unrelated to AstroSharper's infrastructure (we only happen to share the same Supabase project — the `app` discriminator column on every table keeps the two apps' data cleanly separated).

**The Supabase project:** `bpngramreznwvtssrcbe` (`https://bpngramreznwvtssrcbe.supabase.co`). The publishable anon key is committed in `App/SupabaseConfig.swift`.

## What needs to be deployed

```
supabase/
├── migrations/
│   ├── 20260503_astrosharper_extension.sql   # original tables (already applied)
│   └── 20260503_community_feed.sql           # ALTER ADD elapsed_sec ← NEW
└── functions/
    ├── stack-completed/index.ts              # already deployed
    ├── community-thumbnail/index.ts          # UPDATED — accepts elapsedSec
    └── community-feed/index.ts               # NEW — read endpoint
```

The current live state on Supabase:
- `20260503_astrosharper_extension.sql`: applied
- `stack-completed`: deployed and working (telemetry rows are flowing)
- `community-thumbnail`: deployed but **not yet updated** with the elapsedSec field
- `community-feed`: **not deployed** → that's why the Community Stacks window shows HTTP 404

## Path A — Supabase Dashboard (no CLI auth needed)

Fastest if your CLI isn't linked to the project.

### A1. Run the migration

1. Open https://supabase.com/dashboard/project/bpngramreznwvtssrcbe/sql/new
2. Paste the contents of `supabase/migrations/20260503_community_feed.sql`
3. Hit **Run**
4. Verify with: `\d public.community_thumbnails` — should show `elapsed_sec | double precision | nullable`

### A2. Update the `community-thumbnail` function

1. Open https://supabase.com/dashboard/project/bpngramreznwvtssrcbe/functions
2. Click `community-thumbnail` → **Edit function**
3. Replace the entire body with the contents of `supabase/functions/community-thumbnail/index.ts`
4. Click **Deploy updates**

### A3. Create the `community-feed` function

1. Same Functions page → **Deploy a new function**
2. Name: exactly `community-feed`
3. Paste the contents of `supabase/functions/community-feed/index.ts`
4. Click **Deploy function**
5. After ~10 seconds the function URL `https://bpngramreznwvtssrcbe.supabase.co/functions/v1/community-feed` is live

### A4. Smoke test

```bash
curl -i "https://bpngramreznwvtssrcbe.supabase.co/functions/v1/community-feed?limit=10&app=astrosharper" \
  -H "Authorization: Bearer sb_publishable_NROHg8DwJvvdfdyr7JIcog_nILiDe9U" \
  -H "apikey: sb_publishable_NROHg8DwJvvdfdyr7JIcog_nILiDe9U"
```

Expect HTTP 200 + `{"entries":[...]}`. Each entry has a `signedUrl` (1-hour TTL).

## Path B — Supabase CLI (if you log in with the account that owns the project)

```bash
cd /Users/joergklaas/Desktop/claude-code/AstroSharper

# 1. Make sure the CLI is signed in to the account that has access
#    to project bpngramreznwvtssrcbe. The current default `supabase
#    login` session in this directory does NOT have access.
supabase logout
supabase login   # opens browser

# 2. Link the AstroSharper repo to the project (creates supabase/.temp/).
supabase link --project-ref bpngramreznwvtssrcbe

# 3. Push migrations (only the new 20260503_community_feed.sql will
#    actually run — the previous one is already in
#    supabase_migrations.schema_migrations).
supabase db push

# 4. Deploy/redeploy both functions.
supabase functions deploy community-thumbnail
supabase functions deploy community-feed

# 5. Same smoke test as Path A4.
```

## After deployment

1. The "Community Stacks" window in the running AstroSharper app (Help → "Show other peoples' stacks…", or the violet button in the headline bar) calls `community-feed` and renders the entries.
2. Existing rows in `community_thumbnails` will show `—` in the Duration column (their `elapsed_sec` is NULL because they were uploaded before the column existed). New uploads from the latest AstroSharper build start populating that field.
3. Your own rows get a YOU badge + accent-tinted card (matched by `MachineID.current`).

## When something fails

| Symptom | Cause + fix |
|---|---|
| Window shows `HTTP 404 NOT_FOUND` | `community-feed` not deployed yet — see A3 / Path B step 4. |
| `community-thumbnail` returns 400 with old AstroSharper builds | Old build sends payload without `elapsedSec`; the updated validator treats absence as `null` so it should still work. If a 400 persists, the dashboard Edit didn't actually save — re-paste + Deploy updates. |
| `community-feed` returns 500 with `Database error.` | Either the `elapsed_sec` column doesn't exist (migration didn't run — see A1) or the `community-thumbnails` storage bucket doesn't exist. Re-check both. |
| `community-feed` returns 200 but `entries: []` | No matching rows. `WHERE app='astrosharper' AND NOT flagged` is the filter — confirm rows exist with `SELECT app, COUNT(*) FROM community_thumbnails GROUP BY app;`. |
