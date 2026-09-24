-- Number-list sequence lock: store "12, 13, 42, ..." and hash that text.
-- Prize order / adding prizes after lock does not change the stored list.

ALTER TABLE lottery_config
  ADD COLUMN IF NOT EXISTS sequence_numbers TEXT;

-- Build ordered number list:
--   prize numbers by sort_order, then assigned_number;
--   then remaining (thank-you) numbers in random order (so later
--   prize slots can consume a shuffled tail).
CREATE OR REPLACE FUNCTION build_number_sequence()
RETURNS INT[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_out INT[] := ARRAY[]::INT[];
  v_used INT[] := ARRAY[]::INT[];
  v_rest INT[] := ARRAY[]::INT[];
  v_prize RECORD;
  v_num INT;
  v_i INT;
  v_j INT;
  v_tmp INT;
BEGIN
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  FOR v_prize IN
    SELECT p.id
    FROM prizes p
    ORDER BY p.sort_order ASC, p.id ASC
  LOOP
    FOR v_num IN
      SELECT a.assigned_number
      FROM prize_assignments a
      WHERE a.prize_id = v_prize.id
      ORDER BY a.assigned_number ASC
    LOOP
      v_out := array_append(v_out, v_num);
      v_used := array_append(v_used, v_num);
    END LOOP;
  END LOOP;

  FOR v_num IN 1..v_cfg.total_number LOOP
    IF NOT (v_num = ANY (COALESCE(v_used, ARRAY[]::INT[]))) THEN
      v_rest := array_append(v_rest, v_num);
    END IF;
  END LOOP;

  -- Fisher–Yates shuffle of the thank-you / unused tail
  IF coalesce(array_length(v_rest, 1), 0) > 1 THEN
    FOR v_i IN REVERSE array_length(v_rest, 1)..2 LOOP
      v_j := 1 + floor(random() * v_i)::INT;
      v_tmp := v_rest[v_i];
      v_rest[v_i] := v_rest[v_j];
      v_rest[v_j] := v_tmp;
    END LOOP;
  END IF;

  RETURN v_out || COALESCE(v_rest, ARRAY[]::INT[]);
END;
$$;

CREATE OR REPLACE FUNCTION numbers_to_text(p_nums INT[])
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_nums IS NULL OR coalesce(array_length(p_nums, 1), 0) = 0 THEN ''
    ELSE array_to_string(p_nums, ', ')
  END;
$$;

-- Persist a freshly built list when missing (stable until regenerate / unlock).
CREATE OR REPLACE FUNCTION ensure_sequence_numbers()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_nums INT[];
  v_text TEXT;
BEGIN
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF coalesce(v_cfg.sequence_numbers, '') <> '' THEN
    RETURN v_cfg.sequence_numbers;
  END IF;

  IF v_cfg.status = 'setup' THEN
    RAISE EXCEPTION '请先生成奖池后再导出序列';
  END IF;

  v_nums := build_number_sequence();
  v_text := numbers_to_text(v_nums);

  UPDATE lottery_config
  SET sequence_numbers = v_text,
      updated_at = NOW()
  WHERE id = 1;

  RETURN v_text;
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
  v_nums INT[];
  v_text TEXT;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  IF v_cfg.status = 'setup' AND coalesce(v_cfg.sequence_numbers, '') = '' THEN
    RAISE EXCEPTION '请先生成奖池后再导出序列';
  END IF;

  IF v_cfg.sequence_locked AND coalesce(v_cfg.sequence_numbers, '') <> '' THEN
    v_text := v_cfg.sequence_numbers;
  ELSE
    v_text := ensure_sequence_numbers();
  END IF;

  SELECT array_agg(trim(x)::INT ORDER BY ord)
  INTO v_nums
  FROM unnest(string_to_array(v_text, ',')) WITH ORDINALITY AS t(x, ord)
  WHERE trim(x) <> '';

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'numbers', to_jsonb(COALESCE(v_nums, ARRAY[]::INT[])),
    'numbersText', v_text,
    'sequenceLocked', coalesce(v_cfg.sequence_locked, false),
    'sequenceHash', v_cfg.sequence_hash,
    'sequenceLockedAt', v_cfg.sequence_locked_at,
    'sequenceNumbers', v_cfg.sequence_numbers
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
  v_nums INT[];
  v_text TEXT;
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

  -- Reuse stored draft (already shuffled) so hash matches export
  v_text := ensure_sequence_numbers();
  SELECT array_agg(trim(x)::INT ORDER BY ord)
  INTO v_nums
  FROM unnest(string_to_array(v_text, ',')) WITH ORDINALITY AS t(x, ord)
  WHERE trim(x) <> '';

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  IF coalesce(array_length(v_nums, 1), 0) <> v_cfg.total_number THEN
    RAISE EXCEPTION '序列长度异常';
  END IF;

  UPDATE lottery_config
  SET sequence_locked = TRUE,
      sequence_hash = lower(trim(p_hash)),
      sequence_numbers = v_text,
      sequence_locked_at = NOW(),
      updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'ok', true,
    'sequenceLocked', true,
    'sequenceHash', v_cfg.sequence_hash,
    'sequenceNumbers', v_cfg.sequence_numbers,
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
      sequence_numbers = NULL,
      sequence_locked_at = NULL,
      updated_at = NOW()
  WHERE id = 1;
  RETURN jsonb_build_object('ok', true, 'sequenceLocked', false);
END;
$$;

-- Import from number list. Maps onto current prizes by sort_order / quantity.
CREATE OR REPLACE FUNCTION import_lottery_sequence(p_token UUID, p_document JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_nums INT[];
  v_text TEXT;
  v_total INT;
  v_i INT;
  v_n INT;
  v_seen INT[] := ARRAY[]::INT[];
  v_prize RECORD;
  v_qty INT;
  v_idx INT := 1;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.sequence_locked THEN
    RAISE EXCEPTION '奖池序列已锁定，无法导入。请先解锁';
  END IF;

  IF p_document IS NULL OR jsonb_typeof(p_document) <> 'object' THEN
    RAISE EXCEPTION '无效的 JSON 文档';
  END IF;

  -- Prefer numbers array; else parse numbersText
  IF p_document ? 'numbers' AND jsonb_typeof(p_document->'numbers') = 'array' THEN
    SELECT coalesce(array_agg((x)::INT), ARRAY[]::INT[])
    INTO v_nums
    FROM jsonb_array_elements_text(p_document->'numbers') AS t(x);
  ELSIF p_document ? 'numbersText' THEN
    v_text := p_document->>'numbersText';
    SELECT coalesce(array_agg(trim(x)::INT ORDER BY ord), ARRAY[]::INT[])
    INTO v_nums
    FROM unnest(string_to_array(v_text, ',')) WITH ORDINALITY AS t(x, ord)
    WHERE trim(x) <> '';
  ELSE
    RAISE EXCEPTION '缺少 numbers 或 numbersText';
  END IF;

  v_total := coalesce((p_document->>'totalNumber')::INT, array_length(v_nums, 1));

  IF v_total IS NULL OR v_total < 1 THEN
    RAISE EXCEPTION '无效的 totalNumber';
  END IF;

  IF coalesce(array_length(v_nums, 1), 0) <> v_total THEN
    RAISE EXCEPTION 'numbers 长度（%）与 totalNumber（%）不一致',
      coalesce(array_length(v_nums, 1), 0), v_total;
  END IF;

  FOR v_i IN 1..v_total LOOP
    v_n := v_nums[v_i];
    IF v_n IS NULL OR v_n < 1 OR v_n > v_total THEN
      RAISE EXCEPTION '无效的号码：%', coalesce(v_n::TEXT, 'null');
    END IF;
    IF v_n = ANY (v_seen) THEN
      RAISE EXCEPTION '重复的号码：%', v_n;
    END IF;
    v_seen := array_append(v_seen, v_n);
  END LOOP;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  FOR v_prize IN
    SELECT p.id, p.quantity, p.name
    FROM prizes p
    ORDER BY p.sort_order ASC, p.id ASC
  LOOP
    v_qty := v_prize.quantity;
    IF v_idx + v_qty - 1 > v_total THEN
      RAISE EXCEPTION '奖品数量超过总人数（奖品「%」）', v_prize.name;
    END IF;
    FOR v_i IN 1..v_qty LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_prize.id, v_nums[v_idx], FALSE);
      v_idx := v_idx + 1;
    END LOOP;
  END LOOP;

  v_text := numbers_to_text(v_nums);

  UPDATE lottery_config
  SET total_number = v_total,
      current_cursor = 0,
      status = 'running',
      sequence_locked = FALSE,
      sequence_hash = NULL,
      sequence_numbers = v_text,
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
    'sequenceLocked', false,
    'numbersText', v_text
  );
END;
$$;

-- Reorder prizes (list order = prize rank for number-list export when unlocked)
CREATE OR REPLACE FUNCTION admin_reorder_prizes(p_token UUID, p_ids BIGINT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_i INT;
  v_id BIGINT;
  v_count INT;
BEGIN
  PERFORM assert_admin(p_token);

  IF p_ids IS NULL OR coalesce(array_length(p_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION '奖品列表为空';
  END IF;

  SELECT count(*)::INT INTO v_count FROM prizes;
  IF array_length(p_ids, 1) <> v_count THEN
    RAISE EXCEPTION '奖品列表不完整';
  END IF;

  FOR v_i IN 1..array_length(p_ids, 1) LOOP
    v_id := p_ids[v_i];
    IF NOT EXISTS (SELECT 1 FROM prizes WHERE id = v_id) THEN
      RAISE EXCEPTION '奖品不存在：%', v_id;
    END IF;
    UPDATE prizes SET sort_order = v_i - 1 WHERE id = v_id;
  END LOOP;

  -- Unlocked: rebuild next export (new prize prefix + reshuffled tail).
  -- Locked: keep frozen sequence_numbers unchanged.
  UPDATE lottery_config
  SET sequence_numbers = NULL,
      sequence_hash = NULL,
      updated_at = NOW()
  WHERE id = 1 AND sequence_locked = FALSE;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Clear stored numbers when regenerating / restarting
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
  SET current_cursor = 0,
      status = 'running',
      sequence_numbers = NULL,
      sequence_hash = NULL,
      sequence_locked = FALSE,
      sequence_locked_at = NULL,
      updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  -- Build prize prefix + shuffled thank-you tail and persist as draft
  PERFORM ensure_sequence_numbers();
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', false,
    'sequenceNumbers', v_cfg.sequence_numbers
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

  IF v_cfg.sequence_locked THEN
    RAISE EXCEPTION '奖池序列已锁定，无法重新开始。请先解锁';
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
  SET current_cursor = 0,
      status = 'running',
      sequence_numbers = NULL,
      sequence_hash = NULL,
      sequence_locked = FALSE,
      sequence_locked_at = NULL,
      updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  PERFORM ensure_sequence_numbers();
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', false,
    'sequenceNumbers', v_cfg.sequence_numbers
  );
END;
$$;

-- Extend public state
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
  INTO v_prizes
  FROM prizes p;

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
      'sequenceLockedAt', v_cfg.sequence_locked_at,
      'sequenceNumbers', v_cfg.sequence_numbers
    ),
    'prizes', v_prizes,
    'history', v_history,
    'remainingPrizes', v_remaining,
    'drawnPrizes', v_drawn
  );
END;
$$;

GRANT EXECUTE ON FUNCTION build_number_sequence() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION numbers_to_text(INT[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION ensure_sequence_numbers() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_lottery_sequence(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION lock_lottery_sequence(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION unlock_lottery_sequence(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION import_lottery_sequence(UUID, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_reorder_prizes(UUID, BIGINT[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION generate_lottery(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION restart_lottery(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_lottery_state() TO anon, authenticated;
