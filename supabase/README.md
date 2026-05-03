# AstroSharper — Supabase

This directory holds the schema migration + edge functions AstroSharper writes to. **The actual deployment lives in the AstroBlink Supabase project** (project ref `bpngramreznwvtssrcbe`) — both apps share a single project, distinguished by the `app` column on every table.

## Files

```
supabase/
├── migrations/
│   └── 20260503_astrosharper_extension.sql   # ALTER app_events + new tables + RLS
├── functions/
│   ├── stack-completed/
│   │   └── index.ts                          # POST: TelemetryEvent → stack_telemetry
│   └── community-thumbnail/
│       └── index.ts                          # POST: multipart JPEG → community_thumbnails + storage
└── README.md
```

## Deploy

These files need to land in the **AstroBlink repo's** `supabase/` directory and get deployed from there (so the AstroBlink Supabase CLI session knows about them). See the deployment instructions in `tasks/PROMPT_FOR_ASTROBLINK_REPO.md` at the AstroSharper repo root — that's the prompt to paste into AstroBlink's Claude session.

Quick deploy (assuming the files are already in the AstroBlink repo):

```bash
# from inside the AstroBlink repo, with supabase CLI logged in
supabase db push                                # runs the migration
supabase functions deploy stack-completed       # ~10s
supabase functions deploy community-thumbnail   # ~10s
```

The `community-thumbnails` storage bucket needs to be created once via the dashboard (Storage → New bucket, name `community-thumbnails`, public OFF).

## Privacy contract

The complete payload columns are listed in the migration SQL header. Every payload field is documented with the privacy rationale. **No filenames, no hostnames, no email, no IP, no telescope/camera strings.** The only identifying field is the random per-install `machine_uuid`.

The Supabase anon key is published in `App/SupabaseConfig.swift` — that's intentional, mirrors AstroTriage's `BenchmarkConfig.supabaseAnonKey`. The anon key gates only INSERTs; SELECT of personal data is blocked by RLS.

## Activation

`SupabaseConfig.networkEnabled = false` in the Swift client until v0.4.x ships publicly. Flip to `true` and rebuild to start sending real traffic. The bottom-bar status icons + per-stack community prompt sit BELOW that gate — when the gate is off they don't even fire.
