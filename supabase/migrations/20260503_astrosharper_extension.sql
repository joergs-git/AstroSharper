-- AstroSharper extension to the AstroBlink Supabase project (2026-05-03).
--
-- Adds the `app` discriminator to the existing `app_events` table so
-- AstroSharper can share the project without colliding with AstroBlink
-- writes. Then creates two AstroSharper-specific tables:
--   * stack_telemetry      — per-stack-completion event with AutoAP /
--                            AutoPSF parameters. Drives empirical
--                            tuning of the engine's defaults across
--                            the user fleet.
--   * community_thumbnails — opt-in upload of a downscaled JPEG of the
--                            stacked output + minimal metadata for
--                            the public community feed.
--
-- Privacy contract:
--   * `machine_uuid` is a random per-install UUID generated locally on
--     the AstroSharper side (NOT derived from hardware). Different
--     identifier scheme than AstroBlink's SHA256(IOPlatformUUID) by
--     design — AstroSharper users opted for the stronger anonymity
--     posture, AstroBlink leaderboard wants stable hardware identity.
--     Cross-app machine linking is therefore impossible by design.
--   * No filenames, no hostnames, no email, no IP geolocation, no
--     telescope/camera strings. The complete payload columns are
--     listed below; that's the entire contract.
--
-- Idempotency: every CREATE / ALTER / INDEX / POLICY uses IF NOT
-- EXISTS so re-running the migration is a no-op. Safe to apply on a
-- live database without taking writes offline.

BEGIN;

-- =========================================================
-- 1. Add `app` discriminator to existing app_events.
-- =========================================================
-- Existing AstroBlink rows are backfilled to 'astroblink' via the
-- DEFAULT clause; new AstroSharper inserts will write 'astrosharper'
-- explicitly. Zero data loss; ~4 bytes per row added.

ALTER TABLE public.app_events
    ADD COLUMN IF NOT EXISTS app TEXT NOT NULL DEFAULT 'astroblink';

CREATE INDEX IF NOT EXISTS idx_app_events_app_created
    ON public.app_events (app, created_at DESC);

-- =========================================================
-- 2. AstroSharper stack telemetry.
-- =========================================================
-- One row per stack_completed event. The `auto_*` fields capture the
-- engine's per-data decisions so we can tune the closed-form defaults
-- against what actually works across hundreds of captures.

CREATE TABLE IF NOT EXISTS public.stack_telemetry (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app             TEXT NOT NULL DEFAULT 'astrosharper',
    machine_uuid    TEXT NOT NULL,
    schema_version  INT  NOT NULL DEFAULT 1,
    event           TEXT NOT NULL,                     -- 'stack_completed' (only event for now)
    target          TEXT,                              -- sun/moon/jupiter/saturn/mars or null
    frame_count     INT  NOT NULL,
    image_width     INT  NOT NULL,
    image_height    INT  NOT NULL,
    auto_psf_sigma  DOUBLE PRECISION,                  -- nullable: AutoPSF bails on textured
    auto_ap_grid    INT,
    auto_ap_patch   INT,
    shift_sigma     DOUBLE PRECISION,                  -- nullable: nil before gate is wired
    elapsed_sec     DOUBLE PRECISION NOT NULL,
    auto_nuke       BOOLEAN NOT NULL,
    app_version     TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stack_telemetry_app_target_created
    ON public.stack_telemetry (app, target, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stack_telemetry_machine_created
    ON public.stack_telemetry (machine_uuid, created_at DESC);

-- =========================================================
-- 3. AstroSharper community thumbnails.
-- =========================================================
-- Row points at a JPEG that lives in the `community-thumbnails`
-- storage bucket (created separately via the Supabase dashboard or
-- the storage API; the CREATE BUCKET statement isn't a migration
-- primitive). Moderation flag controls public visibility.

CREATE TABLE IF NOT EXISTS public.community_thumbnails (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app             TEXT NOT NULL DEFAULT 'astrosharper',
    machine_uuid    TEXT NOT NULL,
    target          TEXT,
    frame_count     INT,
    storage_path    TEXT NOT NULL,                    -- e.g. 'community/<uuid>/<ts>.jpg'
    app_version     TEXT NOT NULL,
    flagged         BOOLEAN NOT NULL DEFAULT FALSE,   -- moderation hide
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_community_thumbnails_app_target_created
    ON public.community_thumbnails (app, target, created_at DESC)
    WHERE NOT flagged;
CREATE INDEX IF NOT EXISTS idx_community_thumbnails_machine_created
    ON public.community_thumbnails (machine_uuid, created_at DESC);

-- =========================================================
-- 4. RLS — anon writes only; community thumbnails public read.
-- =========================================================
-- Mirrors the AstroBlink app_events policy: anon clients (the apps
-- themselves, holding the publishable anon key) can INSERT but
-- cannot SELECT individual rows. This stops one user from reading
-- another user's events from the client side.
--
-- community_thumbnails has an additional public SELECT policy so the
-- community feed can render without authentication, gated to rows
-- that haven't been moderation-flagged.

ALTER TABLE public.stack_telemetry      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.community_thumbnails ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                   WHERE schemaname = 'public'
                     AND tablename  = 'stack_telemetry'
                     AND policyname = 'anon_insert_stack_telemetry') THEN
        CREATE POLICY "anon_insert_stack_telemetry"
            ON public.stack_telemetry
            FOR INSERT TO anon
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies
                   WHERE schemaname = 'public'
                     AND tablename  = 'community_thumbnails'
                     AND policyname = 'anon_insert_community_thumbnails') THEN
        CREATE POLICY "anon_insert_community_thumbnails"
            ON public.community_thumbnails
            FOR INSERT TO anon
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies
                   WHERE schemaname = 'public'
                     AND tablename  = 'community_thumbnails'
                     AND policyname = 'public_read_community_thumbnails') THEN
        CREATE POLICY "public_read_community_thumbnails"
            ON public.community_thumbnails
            FOR SELECT TO anon
            USING (NOT flagged);
    END IF;
END $$;

COMMIT;

-- =========================================================
-- POST-MIGRATION CHECKLIST (manual, not auto-executed):
-- =========================================================
-- 1. Verify backfill: SELECT app, COUNT(*) FROM public.app_events GROUP BY app;
--    → should show 'astroblink' row equal to the prior total count.
-- 2. Create the storage bucket via dashboard or supabase-js:
--      supabase.storage.createBucket('community-thumbnails', { public: false })
--    Then add a policy allowing anon uploads via the edge function's
--    service-role key. JPEGs themselves never leave via anon — they
--    go through the community-thumbnail edge function which holds
--    the service-role key server-side.
-- 3. Deploy the edge functions:
--      supabase functions deploy stack-completed
--      supabase functions deploy community-thumbnail
-- 4. Smoke test from the AstroSharper Swift client (TELEMETRY_ENABLED
--    flipped on locally) — expect HTTP 201 from both endpoints.
