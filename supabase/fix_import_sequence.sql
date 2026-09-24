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
