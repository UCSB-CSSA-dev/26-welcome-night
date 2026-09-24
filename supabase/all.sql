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
-- Lottery generate / draw / restart / adjust

CREATE OR REPLACE FUNCTION expand_prize_units()
RETURNS TABLE(prize_id BIGINT)
LANGUAGE sql
STABLE
AS $$
  SELECT p.id
  FROM prizes p
  CROSS JOIN LATERAL generate_series(1, p.quantity) AS g
  ORDER BY p.sort_order, p.id;
$$;

CREATE OR REPLACE FUNCTION pick_unique_numbers(p_count INT, p_min INT, p_max INT)
RETURNS INT[]
LANGUAGE plpgsql
AS $$
DECLARE
  v_available INT;
  v_pool INT[];
  v_result INT[];
  v_i INT;
  v_j INT;
  v_tmp INT;
BEGIN
  v_available := p_max - p_min + 1;
  IF p_count < 0 THEN
    RAISE EXCEPTION '数量不能为负';
  END IF;
  IF p_count > v_available THEN
    RAISE EXCEPTION '剩余奖品数量（%）超过可用号码（%：%–%）',
      p_count, v_available, p_min, p_max;
  END IF;

  SELECT array_agg(n) INTO v_pool
  FROM generate_series(p_min, p_max) AS n;

  -- Fisher–Yates
  FOR v_i IN REVERSE array_length(v_pool, 1)..2 LOOP
    v_j := 1 + floor(random() * v_i)::INT;
    v_tmp := v_pool[v_i];
    v_pool[v_i] := v_pool[v_j];
    v_pool[v_j] := v_tmp;
  END LOOP;

  v_result := v_pool[1:p_count];
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION generate_lottery(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_units BIGINT[];
  v_nums INT[];
  v_i INT;
BEGIN
  PERFORM assert_admin(p_token);

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.status <> 'setup' AND v_cfg.current_cursor > 0 THEN
    RAISE EXCEPTION '抽奖进行中，请先「重新开始」或使用「调整总数」';
  END IF;

  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0, status = 'running', updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION restart_lottery(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_units BIGINT[];
  v_nums INT[];
  v_i INT;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0, status = 'running', updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION set_total_number(p_token UUID, p_total INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_remaining BIGINT[];
  v_occupied INT[];
  v_free INT[];
  v_pool INT[];
  v_i INT;
  v_j INT;
  v_tmp INT;
  v_need INT;
  v_status TEXT;
BEGIN
  PERFORM assert_admin(p_token);

  IF p_total IS NULL OR p_total < 1 THEN
    RAISE EXCEPTION '总人数必须是正整数';
  END IF;

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.status = 'setup' THEN
    UPDATE lottery_config
    SET total_number = p_total, updated_at = NOW()
    WHERE id = 1
    RETURNING * INTO v_cfg;
  ELSE
    IF p_total < v_cfg.current_cursor THEN
      RAISE EXCEPTION '新总人数（%）不能小于已抽序号（%）',
        p_total, v_cfg.current_cursor;
    END IF;

    SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
    INTO v_remaining
    FROM prize_assignments WHERE drawn = FALSE;

    SELECT coalesce(array_agg(assigned_number), ARRAY[]::INT[])
    INTO v_occupied
    FROM prize_assignments WHERE drawn = TRUE;

    DELETE FROM prize_assignments WHERE drawn = FALSE;

    v_need := coalesce(array_length(v_remaining, 1), 0);
    v_pool := ARRAY[]::INT[];
    FOR v_i IN (v_cfg.current_cursor + 1)..p_total LOOP
      IF NOT (v_i = ANY (v_occupied)) THEN
        v_pool := array_append(v_pool, v_i);
      END IF;
    END LOOP;

    IF v_need > coalesce(array_length(v_pool, 1), 0) THEN
      RAISE EXCEPTION '剩余奖品（%）超过可用号码（%）',
        v_need, coalesce(array_length(v_pool, 1), 0);
    END IF;

    IF v_need > 0 THEN
      FOR v_i IN REVERSE array_length(v_pool, 1)..2 LOOP
        v_j := 1 + floor(random() * v_i)::INT;
        v_tmp := v_pool[v_i];
        v_pool[v_i] := v_pool[v_j];
        v_pool[v_j] := v_tmp;
      END LOOP;
      v_free := v_pool[1:v_need];
      FOR v_i IN 1..v_need LOOP
        INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
        VALUES (v_remaining[v_i], v_free[v_i], FALSE);
      END LOOP;
    END IF;

    IF v_cfg.current_cursor >= p_total THEN
      v_status := 'finished';
    ELSE
      v_status := 'running';
    END IF;

    UPDATE lottery_config
    SET total_number = p_total, status = v_status, updated_at = NOW()
    WHERE id = 1
    RETURNING * INTO v_cfg;
  END IF;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION draw_next(p_session_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session sessions%ROWTYPE;
  v_cfg lottery_config%ROWTYPE;
  v_next INT;
  v_asg prize_assignments%ROWTYPE;
  v_prize prizes%ROWTYPE;
  v_finished BOOLEAN;
  v_won BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_session FROM sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '设备会话不存在';
  END IF;
  IF NOT v_session.approved THEN
    RAISE EXCEPTION '设备尚未通过管理员审批';
  END IF;

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.status = 'setup' THEN
    RAISE EXCEPTION '抽奖尚未开始，请管理员先生成奖池';
  END IF;
  IF v_cfg.current_cursor >= v_cfg.total_number THEN
    UPDATE lottery_config SET status = 'finished', updated_at = NOW() WHERE id = 1;
    RAISE EXCEPTION '抽奖已结束';
  END IF;

  v_next := v_cfg.current_cursor + 1;

  SELECT * INTO v_asg
  FROM prize_assignments
  WHERE assigned_number = v_next AND drawn = FALSE
  FOR UPDATE;

  IF FOUND THEN
    SELECT * INTO v_prize FROM prizes WHERE id = v_asg.prize_id;
    UPDATE prize_assignments
    SET drawn = TRUE, drawn_at = NOW(), drawn_by_session = p_session_id
    WHERE id = v_asg.id;

    INSERT INTO draw_history (order_number, prize_id, assignment_id, session_id)
    VALUES (v_next, v_prize.id, v_asg.id, p_session_id);
    v_won := TRUE;
  ELSE
    INSERT INTO draw_history (order_number, prize_id, assignment_id, session_id)
    VALUES (v_next, NULL, NULL, p_session_id);
  END IF;

  v_finished := v_next >= v_cfg.total_number;
  UPDATE lottery_config
  SET current_cursor = v_next,
      status = CASE WHEN v_finished THEN 'finished' ELSE 'running' END,
      updated_at = NOW()
  WHERE id = 1;

  IF v_won THEN
    RETURN jsonb_build_object(
      'orderNumber', v_next,
      'thankYou', false,
      'finished', v_finished,
      'prize', jsonb_build_object(
        'id', v_prize.id,
        'name', v_prize.name,
        'description', v_prize.description,
        'quantity', v_prize.quantity,
        'imagePath', v_prize.image_path,
        'sortOrder', v_prize.sort_order
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'orderNumber', v_next,
    'thankYou', true,
    'finished', v_finished,
    'prize', NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION create_device_session(p_label TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
  v_id UUID;
  v_label TEXT;
  v_created TIMESTAMPTZ;
  v_attempt INT := 0;
BEGIN
  v_label := coalesce(trim(p_label), '');
  LOOP
    v_attempt := v_attempt + 1;
    v_code := lpad((floor(random() * 900000) + 100000)::INT::TEXT, 6, '0');
    BEGIN
      INSERT INTO sessions (code, approved, label)
      VALUES (v_code, FALSE, v_label)
      RETURNING id, created_at INTO v_id, v_created;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_attempt > 20 THEN
        RAISE EXCEPTION '无法生成唯一设备码，请重试';
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'id', v_id,
    'code', v_code,
    'approved', false,
    'label', v_label,
    'createdAt', v_created
  );
END;
$$;

CREATE OR REPLACE FUNCTION set_session_approved(
  p_token UUID,
  p_session_id UUID,
  p_approved BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row sessions%ROWTYPE;
BEGIN
  PERFORM assert_admin(p_token);
  UPDATE sessions SET approved = p_approved WHERE id = p_session_id
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION '设备会话不存在';
  END IF;
  RETURN jsonb_build_object(
    'id', v_row.id,
    'code', v_row.code,
    'approved', v_row.approved,
    'label', v_row.label,
    'createdAt', v_row.created_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION admin_create_prize(
  p_token UUID,
  p_name TEXT,
  p_description TEXT,
  p_quantity INT,
  p_image_path TEXT DEFAULT NULL,
  p_sort_order INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row prizes%ROWTYPE;
  v_cfg lottery_config%ROWTYPE;
  v_sum INT;
BEGIN
  PERFORM assert_admin(p_token);
  IF trim(p_name) = '' THEN
    RAISE EXCEPTION '奖品名称不能为空';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 THEN
    RAISE EXCEPTION '奖品数量必须是正整数';
  END IF;

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;
  SELECT coalesce(sum(quantity), 0) INTO v_sum FROM prizes;
  IF v_sum + p_quantity > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数将超过总人数（%），请先调整总数或减少数量',
      v_cfg.total_number;
  END IF;

  INSERT INTO prizes (name, description, quantity, image_path, sort_order)
  VALUES (trim(p_name), coalesce(p_description, ''), p_quantity, p_image_path, coalesce(p_sort_order, 0))
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'description', v_row.description,
    'quantity', v_row.quantity,
    'imagePath', v_row.image_path,
    'sortOrder', v_row.sort_order
  );
END;
$$;

CREATE OR REPLACE FUNCTION admin_update_prize(
  p_token UUID,
  p_id BIGINT,
  p_name TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_quantity INT DEFAULT NULL,
  p_image_path TEXT DEFAULT NULL,
  p_sort_order INT DEFAULT NULL,
  p_clear_image BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row prizes%ROWTYPE;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_row FROM prizes WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '奖品不存在';
  END IF;

  UPDATE prizes SET
    name = coalesce(nullif(trim(p_name), ''), name),
    description = CASE WHEN p_description IS NULL THEN description ELSE p_description END,
    quantity = CASE
      WHEN p_quantity IS NULL THEN quantity
      WHEN p_quantity < 1 THEN quantity
      ELSE p_quantity
    END,
    image_path = CASE
      WHEN p_clear_image THEN NULL
      WHEN p_image_path IS NULL THEN image_path
      ELSE p_image_path
    END,
    sort_order = coalesce(p_sort_order, sort_order)
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'description', v_row.description,
    'quantity', v_row.quantity,
    'imagePath', v_row.image_path,
    'sortOrder', v_row.sort_order
  );
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_prize(p_token UUID, p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);

  IF NOT EXISTS (SELECT 1 FROM prizes WHERE id = p_id) THEN
    RAISE EXCEPTION '奖品不存在';
  END IF;

  DELETE FROM prizes WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION get_lottery_state()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_prizes JSONB;
  v_history JSONB;
  v_remaining INT;
  v_drawn INT;
BEGIN
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'description', p.description,
    'quantity', p.quantity,
    'imagePath', p.image_path,
    'sortOrder', p.sort_order
  ) ORDER BY p.sort_order, p.id), '[]'::jsonb)
  INTO v_prizes FROM prizes p;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'orderNumber', h.order_number,
    'prizeId', h.prize_id,
    'prizeName', p.name,
    'sessionId', h.session_id,
    'createdAt', h.created_at
  ) ORDER BY h.order_number DESC), '[]'::jsonb)
  INTO v_history
  FROM (
    SELECT * FROM draw_history ORDER BY order_number DESC LIMIT 50
  ) h
  LEFT JOIN prizes p ON p.id = h.prize_id;

  SELECT count(*)::INT INTO v_remaining FROM prize_assignments WHERE drawn = FALSE;
  SELECT count(*)::INT INTO v_drawn FROM prize_assignments WHERE drawn = TRUE;

  RETURN jsonb_build_object(
    'config', jsonb_build_object(
      'totalNumber', v_cfg.total_number,
      'currentCursor', v_cfg.current_cursor,
      'status', v_cfg.status,
      'updatedAt', v_cfg.updated_at
    ),
    'prizes', v_prizes,
    'history', v_history,
    'remainingPrizes', v_remaining,
    'drawnPrizes', v_drawn
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_login(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_logout(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_me(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION set_admin_password(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION generate_lottery(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION restart_lottery(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION set_total_number(UUID, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION draw_next(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION create_device_session(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION set_session_approved(UUID, UUID, BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_create_prize(UUID, TEXT, TEXT, INT, TEXT, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_update_prize(UUID, BIGINT, TEXT, TEXT, INT, TEXT, INT, BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_prize(UUID, BIGINT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_lottery_state() TO anon, authenticated;
-- Storage bucket for prize images (public read)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'prize-images',
  'prize-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Allow anon upload only when a valid admin token is passed via a workaround:
-- Clients upload via Edge Function. For SQL-only setup, allow authenticated
-- inserts is not enough. We use a permissive insert policy gated by checking
-- that the object name starts with a valid pattern; actual auth is Edge Function.
-- For simplicity in free-tier SQL setup: allow public INSERT to this bucket
-- (event-night scoped). Tighten later with Edge Function if needed.

DROP POLICY IF EXISTS prize_images_public_read ON storage.objects;
CREATE POLICY prize_images_public_read ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'prize-images');

DROP POLICY IF EXISTS prize_images_public_insert ON storage.objects;
CREATE POLICY prize_images_public_insert ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'prize-images');

DROP POLICY IF EXISTS prize_images_public_update ON storage.objects;
CREATE POLICY prize_images_public_update ON storage.objects
  FOR UPDATE TO anon, authenticated
  USING (bucket_id = 'prize-images');

DROP POLICY IF EXISTS prize_images_public_delete ON storage.objects;
CREATE POLICY prize_images_public_delete ON storage.objects
  FOR DELETE TO anon, authenticated
  USING (bucket_id = 'prize-images');
-- Allow deleting prizes even mid-lottery
CREATE OR REPLACE FUNCTION admin_delete_prize(p_token UUID, p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);

  IF NOT EXISTS (SELECT 1 FROM prizes WHERE id = p_id) THEN
    RAISE EXCEPTION '奖品不存在';
  END IF;

  -- Cascades undrawn/drawn assignments; draw_history.prize_id becomes NULL
  DELETE FROM prizes WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;
-- Sequence lock + export support
ALTER TABLE lottery_config
  ADD COLUMN IF NOT EXISTS sequence_locked BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS sequence_hash TEXT,
  ADD COLUMN IF NOT EXISTS sequence_locked_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION set_total_number(p_token UUID, p_total INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_remaining BIGINT[];
  v_occupied INT[];
  v_free INT[];
  v_pool INT[];
  v_i INT;
  v_j INT;
  v_tmp INT;
  v_need INT;
  v_status TEXT;
BEGIN
  PERFORM assert_admin(p_token);

  IF p_total IS NULL OR p_total < 1 THEN
    RAISE EXCEPTION '总人数必须是正整数';
  END IF;

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.sequence_locked THEN
    RAISE EXCEPTION '奖池序列已锁定，无法调整总数。请先重新开始或解锁';
  END IF;

  IF v_cfg.status = 'setup' THEN
    UPDATE lottery_config
    SET total_number = p_total, updated_at = NOW()
    WHERE id = 1
    RETURNING * INTO v_cfg;
  ELSE
    IF p_total < v_cfg.current_cursor THEN
      RAISE EXCEPTION '新总人数（%）不能小于已抽序号（%）',
        p_total, v_cfg.current_cursor;
    END IF;

    SELECT coalesce(array_agg(prize_id ORDER BY id), ARRAY[]::BIGINT[])
    INTO v_remaining
    FROM prize_assignments WHERE drawn = FALSE;

    SELECT coalesce(array_agg(assigned_number), ARRAY[]::INT[])
    INTO v_occupied
    FROM prize_assignments WHERE drawn = TRUE;

    DELETE FROM prize_assignments WHERE drawn = FALSE;

    v_need := coalesce(array_length(v_remaining, 1), 0);
    v_pool := ARRAY[]::INT[];
    FOR v_i IN (v_cfg.current_cursor + 1)..p_total LOOP
      IF NOT (v_i = ANY (COALESCE(v_occupied, ARRAY[]::INT[]))) THEN
        v_pool := array_append(v_pool, v_i);
      END IF;
    END LOOP;

    IF v_need > coalesce(array_length(v_pool, 1), 0) THEN
      RAISE EXCEPTION '剩余奖品（%）超过可用号码（%）',
        v_need, coalesce(array_length(v_pool, 1), 0);
    END IF;

    IF v_need > 0 THEN
      FOR v_i IN REVERSE array_length(v_pool, 1)..2 LOOP
        v_j := 1 + floor(random() * v_i)::INT;
        v_tmp := v_pool[v_i];
        v_pool[v_i] := v_pool[v_j];
        v_pool[v_j] := v_tmp;
      END LOOP;
      v_free := v_pool[1:v_need];
      FOR v_i IN 1..v_need LOOP
        INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
        VALUES (v_remaining[v_i], v_free[v_i], FALSE);
      END LOOP;
    END IF;

    IF v_cfg.current_cursor >= p_total THEN
      v_status := 'finished';
    ELSE
      v_status := 'running';
    END IF;

    UPDATE lottery_config
    SET total_number = p_total, status = v_status, updated_at = NOW()
    WHERE id = 1
    RETURNING * INTO v_cfg;
  END IF;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', v_cfg.sequence_locked
  );
END;
$$;

CREATE OR REPLACE FUNCTION generate_lottery(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_units BIGINT[];
  v_nums INT[];
  v_i INT;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.sequence_locked THEN
    RAISE EXCEPTION '奖池序列已锁定，无法重新生成。请先解锁';
  END IF;

  IF v_cfg.status <> 'setup' AND v_cfg.current_cursor > 0 THEN
    RAISE EXCEPTION '抽奖进行中，请先「重新开始」或使用「调整总数」';
  END IF;

  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0, status = 'running', updated_at = NOW(),
      sequence_locked = FALSE, sequence_hash = NULL, sequence_locked_at = NULL
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION restart_lottery(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_units BIGINT[];
  v_nums INT[];
  v_i INT;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  -- Restart clears lock and regenerates
  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0, status = 'running', updated_at = NOW(),
      sequence_locked = FALSE, sequence_hash = NULL, sequence_locked_at = NULL
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', false
  );
END;
$$;

-- Build full 1..N sequence as JSONB array
CREATE OR REPLACE FUNCTION build_lottery_sequence_json()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_seq JSONB := '[]'::JSONB;
  v_i INT;
  v_asg RECORD;
  v_item JSONB;
BEGIN
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  FOR v_i IN 1..v_cfg.total_number LOOP
    SELECT a.prize_id, a.drawn, p.name AS prize_name, p.description AS prize_description
    INTO v_asg
    FROM prize_assignments a
    LEFT JOIN prizes p ON p.id = a.prize_id
    WHERE a.assigned_number = v_i;

    IF FOUND AND v_asg.prize_id IS NOT NULL THEN
      v_item := jsonb_build_object(
        'order', v_i,
        'type', 'prize',
        'prizeId', v_asg.prize_id,
        'prizeName', v_asg.prize_name,
        'prizeDescription', coalesce(v_asg.prize_description, ''),
        'drawn', v_asg.drawn
      );
    ELSE
      v_item := jsonb_build_object(
        'order', v_i,
        'type', 'thank_you',
        'drawn', v_i <= v_cfg.current_cursor
      );
    END IF;

    v_seq := v_seq || jsonb_build_array(v_item);
  END LOOP;

  RETURN jsonb_build_object(
    'event', 'UCSB CSSA Welcome Night 抽奖',
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'sequence', v_seq
  );
END;
$$;

CREATE OR REPLACE FUNCTION get_lottery_sequence(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_payload JSONB;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  IF v_cfg.status = 'setup' THEN
    RAISE EXCEPTION '请先生成奖池后再导出序列';
  END IF;

  v_payload := build_lottery_sequence_json();
  RETURN v_payload || jsonb_build_object(
    'sequenceLocked', v_cfg.sequence_locked,
    'sequenceHash', v_cfg.sequence_hash,
    'sequenceLockedAt', v_cfg.sequence_locked_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION lock_lottery_sequence(p_token UUID, p_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
BEGIN
  PERFORM assert_admin(p_token);

  IF p_hash IS NULL OR length(trim(p_hash)) < 32 THEN
    RAISE EXCEPTION '无效的哈希值';
  END IF;

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.status = 'setup' THEN
    RAISE EXCEPTION '请先生成奖池后再锁定序列';
  END IF;

  IF v_cfg.sequence_locked THEN
    RAISE EXCEPTION '序列已经锁定';
  END IF;

  UPDATE lottery_config
  SET sequence_locked = TRUE,
      sequence_hash = lower(trim(p_hash)),
      sequence_locked_at = NOW(),
      updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'ok', true,
    'sequenceLocked', true,
    'sequenceHash', v_cfg.sequence_hash,
    'sequenceLockedAt', v_cfg.sequence_locked_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION unlock_lottery_sequence(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);
  UPDATE lottery_config
  SET sequence_locked = FALSE,
      sequence_hash = NULL,
      sequence_locked_at = NULL,
      updated_at = NOW()
  WHERE id = 1;
  RETURN jsonb_build_object('ok', true, 'sequenceLocked', false);
END;
$$;

-- Extend public state with lock info
CREATE OR REPLACE FUNCTION get_lottery_state()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_prizes JSONB;
  v_history JSONB;
  v_remaining INT;
  v_drawn INT;
BEGIN
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'description', p.description,
    'quantity', p.quantity,
    'imagePath', p.image_path,
    'sortOrder', p.sort_order
  ) ORDER BY p.sort_order, p.id), '[]'::jsonb)
  INTO v_prizes FROM prizes p;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'orderNumber', h.order_number,
    'prizeId', h.prize_id,
    'prizeName', p.name,
    'sessionId', h.session_id,
    'createdAt', h.created_at
  ) ORDER BY h.order_number DESC), '[]'::jsonb)
  INTO v_history
  FROM (
    SELECT * FROM draw_history ORDER BY order_number DESC LIMIT 50
  ) h
  LEFT JOIN prizes p ON p.id = h.prize_id;

  SELECT count(*)::INT INTO v_remaining FROM prize_assignments WHERE drawn = FALSE;
  SELECT count(*)::INT INTO v_drawn FROM prize_assignments WHERE drawn = TRUE;

  RETURN jsonb_build_object(
    'config', jsonb_build_object(
      'totalNumber', v_cfg.total_number,
      'currentCursor', v_cfg.current_cursor,
      'status', v_cfg.status,
      'updatedAt', v_cfg.updated_at,
      'sequenceLocked', coalesce(v_cfg.sequence_locked, false),
      'sequenceHash', v_cfg.sequence_hash,
      'sequenceLockedAt', v_cfg.sequence_locked_at
    ),
    'prizes', v_prizes,
    'history', v_history,
    'remainingPrizes', v_remaining,
    'drawnPrizes', v_drawn
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_lottery_sequence(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION lock_lottery_sequence(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION unlock_lottery_sequence(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION build_lottery_sequence_json() TO anon, authenticated;
-- Delete device session (user must re-apply for a new code)
CREATE OR REPLACE FUNCTION admin_delete_session(p_token UUID, p_session_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);

  IF NOT EXISTS (SELECT 1 FROM sessions WHERE id = p_session_id) THEN
    RAISE EXCEPTION '设备会话不存在';
  END IF;

  -- draw_history.session_id is ON DELETE SET NULL
  DELETE FROM sessions WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_delete_session(UUID, UUID) TO anon, authenticated;
-- Import lottery sequence from canonical JSON (exported for SHA-256 verify)
CREATE OR REPLACE FUNCTION import_lottery_sequence(p_token UUID, p_document JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_total INT;
  v_seq JSONB;
  v_item JSONB;
  v_i INT;
  v_order INT;
  v_type TEXT;
  v_prize_id BIGINT;
  v_seen INT[] := ARRAY[]::INT[];
BEGIN
  PERFORM assert_admin(p_token);

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.sequence_locked THEN
    RAISE EXCEPTION '奖池序列已锁定，无法导入。请先解锁';
  END IF;

  IF p_document IS NULL OR jsonb_typeof(p_document) <> 'object' THEN
    RAISE EXCEPTION '无效的 JSON 文档';
  END IF;

  v_total := (p_document->>'totalNumber')::INT;
  v_seq := p_document->'sequence';

  IF v_total IS NULL OR v_total < 1 THEN
    RAISE EXCEPTION '无效的 totalNumber';
  END IF;

  IF v_seq IS NULL OR jsonb_typeof(v_seq) <> 'array' THEN
    RAISE EXCEPTION '无效的 sequence';
  END IF;

  IF jsonb_array_length(v_seq) <> v_total THEN
    RAISE EXCEPTION 'sequence 长度（%）与 totalNumber（%）不一致',
      jsonb_array_length(v_seq), v_total;
  END IF;

  FOR v_i IN 0..(v_total - 1) LOOP
    v_item := v_seq->v_i;
    IF v_item IS NULL OR jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION '无效的 sequence 项（下标 %）', v_i;
    END IF;

    v_order := (v_item->>'order')::INT;
    v_type := v_item->>'type';

    IF v_order IS NULL OR v_order < 1 OR v_order > v_total THEN
      RAISE EXCEPTION '无效的 order：%', coalesce(v_order::TEXT, 'null');
    END IF;

    IF v_order = ANY (v_seen) THEN
      RAISE EXCEPTION '重复的 order：%', v_order;
    END IF;
    v_seen := array_append(v_seen, v_order);

    IF v_type = 'prize' THEN
      v_prize_id := (v_item->>'prizeId')::BIGINT;
      IF v_prize_id IS NULL THEN
        RAISE EXCEPTION '序号 % 缺少 prizeId', v_order;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM prizes WHERE id = v_prize_id) THEN
        RAISE EXCEPTION '奖品 ID % 不存在（序号 %）', v_prize_id, v_order;
      END IF;
    ELSIF v_type IS DISTINCT FROM 'thank_you' THEN
      RAISE EXCEPTION '无效的 type：%（序号 %）', coalesce(v_type, 'null'), v_order;
    END IF;
  END LOOP;

  IF coalesce(array_length(v_seen, 1), 0) <> v_total THEN
    RAISE EXCEPTION 'sequence 缺少部分序号';
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  FOR v_i IN 0..(v_total - 1) LOOP
    v_item := v_seq->v_i;
    IF v_item->>'type' = 'prize' THEN
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (
        (v_item->>'prizeId')::BIGINT,
        (v_item->>'order')::INT,
        FALSE
      );
    END IF;
  END LOOP;

  UPDATE lottery_config
  SET total_number = v_total,
      current_cursor = 0,
      status = 'running',
      sequence_locked = FALSE,
      sequence_hash = NULL,
      sequence_locked_at = NULL,
      updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'ok', true,
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION import_lottery_sequence(UUID, JSONB) TO anon, authenticated;
