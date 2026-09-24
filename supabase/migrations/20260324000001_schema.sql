-- UCSB CSSA Welcome Night 抽奖 schema + RPCs
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Config (singleton)
CREATE TABLE IF NOT EXISTS lottery_config (
  id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  total_number INTEGER NOT NULL DEFAULT 100,
  current_cursor INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'setup'
    CHECK (status IN ('setup', 'running', 'finished')),
  admin_password_hash TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO lottery_config (id, total_number, current_cursor, status)
VALUES (1, 100, 0, 'setup')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS prizes (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  image_path TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS prize_assignments (
  id BIGSERIAL PRIMARY KEY,
  prize_id BIGINT NOT NULL REFERENCES prizes(id) ON DELETE CASCADE,
  assigned_number INTEGER NOT NULL UNIQUE,
  drawn BOOLEAN NOT NULL DEFAULT FALSE,
  drawn_at TIMESTAMPTZ,
  drawn_by_session UUID
);

CREATE INDEX IF NOT EXISTS prize_assignments_prize_id_idx ON prize_assignments(prize_id);
CREATE INDEX IF NOT EXISTS prize_assignments_drawn_idx ON prize_assignments(drawn);
CREATE INDEX IF NOT EXISTS prize_assignments_number_idx ON prize_assignments(assigned_number);

CREATE TABLE IF NOT EXISTS sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  approved BOOLEAN NOT NULL DEFAULT FALSE,
  label TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS draw_history (
  id BIGSERIAL PRIMARY KEY,
  order_number INTEGER NOT NULL UNIQUE,
  prize_id BIGINT REFERENCES prizes(id) ON DELETE SET NULL,
  assignment_id BIGINT REFERENCES prize_assignments(id) ON DELETE SET NULL,
  session_id UUID REFERENCES sessions(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS draw_history_created_at_idx ON draw_history(created_at DESC);

CREATE TABLE IF NOT EXISTS admin_tokens (
  token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS: public read for display; writes only via SECURITY DEFINER RPCs
ALTER TABLE lottery_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE prizes ENABLE ROW LEVEL SECURITY;
ALTER TABLE prize_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE draw_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lottery_config_public_read ON lottery_config;
CREATE POLICY lottery_config_public_read ON lottery_config
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS prizes_public_read ON prizes;
CREATE POLICY prizes_public_read ON prizes
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS assignments_public_read ON prize_assignments;
CREATE POLICY assignments_public_read ON prize_assignments
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS sessions_public_read ON sessions;
CREATE POLICY sessions_public_read ON sessions
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS history_public_read ON draw_history;
CREATE POLICY history_public_read ON draw_history
  FOR SELECT TO anon, authenticated USING (true);

-- No direct insert/update/delete for anon on any table (RPCs only)

-- Helpers
CREATE OR REPLACE FUNCTION assert_admin(p_token UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_token IS NULL OR NOT EXISTS (
    SELECT 1 FROM admin_tokens
    WHERE token = p_token AND expires_at > NOW()
  ) THEN
    RAISE EXCEPTION '未登录管理员或登录已过期';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION set_admin_password(p_password TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_password IS NULL OR length(p_password) < 4 THEN
    RAISE EXCEPTION '密码至少 4 位';
  END IF;
  UPDATE lottery_config
  SET admin_password_hash = crypt(p_password, gen_salt('bf')),
      updated_at = NOW()
  WHERE id = 1;
END;
$$;

CREATE OR REPLACE FUNCTION admin_login(p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash TEXT;
  v_token UUID;
  v_expires TIMESTAMPTZ;
BEGIN
  SELECT admin_password_hash INTO v_hash FROM lottery_config WHERE id = 1;
  IF v_hash IS NULL OR v_hash = '' THEN
    RAISE EXCEPTION '管理员密码尚未初始化，请在 Supabase 中执行 set_admin_password';
  END IF;
  IF crypt(p_password, v_hash) <> v_hash THEN
    RAISE EXCEPTION '密码错误';
  END IF;

  DELETE FROM admin_tokens WHERE expires_at < NOW();
  v_expires := NOW() + INTERVAL '12 hours';
  INSERT INTO admin_tokens (expires_at) VALUES (v_expires)
  RETURNING token INTO v_token;

  RETURN jsonb_build_object('token', v_token, 'expiresAt', v_expires);
END;
$$;

CREATE OR REPLACE FUNCTION admin_logout(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM admin_tokens WHERE token = p_token;
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION admin_me(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);
  RETURN jsonb_build_object('ok', true);
END;
$$;
