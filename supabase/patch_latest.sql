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
-- Fix: Supabase rejects DELETE without WHERE (pg_safeupdate)
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
