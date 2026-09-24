-- Fix pgcrypto on Supabase (functions live in schema "extensions")
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

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

-- Set password
SELECT set_admin_password('SBCSSA2026');
