/** Canonical JSON stringify (sorted object keys, no extra whitespace) */
export function canonicalStringify(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortKeys);
  }
  if (value !== null && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(obj).sort()) {
      out[key] = sortKeys(obj[key]);
    }
    return out;
  }
  return value;
}

export async function sha256Hex(text: string): Promise<string> {
  const data = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

type RawSequenceItem = {
  order?: number;
  type?: string;
  prizeId?: number;
  prizeName?: string;
  prizeDescription?: string;
  drawn?: boolean;
};

/**
 * Immutable document used for SHA-256.
 * Excludes mutable fields like drawn / cursor / lock metadata.
 */
export function buildHashDocument(payload: unknown): {
  event: string;
  totalNumber: number;
  sequence: Array<{
    order: number;
    type: string;
    prizeId?: number;
    prizeName?: string;
  }>;
} {
  const body = payload as {
    event?: string;
    totalNumber?: number;
    sequence?: RawSequenceItem[];
  };

  const sequence: Array<{
    order: number;
    type: string;
    prizeId?: number;
    prizeName?: string;
  }> = (body.sequence ?? []).map((item) => {
    if (item.type === "prize") {
      return {
        order: Number(item.order),
        prizeId: Number(item.prizeId),
        prizeName: String(item.prizeName ?? ""),
        type: "prize",
      };
    }
    return {
      order: Number(item.order),
      type: "thank_you",
    };
  });

  sequence.sort((a, b) => a.order - b.order);

  return {
    event: String(body.event ?? "UCSB CSSA Welcome Night 抽奖"),
    sequence,
    totalNumber: Number(body.totalNumber),
  };
}

export async function hashSequencePayload(
  payload: unknown,
): Promise<{ canonicalJson: string; hash: string; document: unknown }> {
  const document = buildHashDocument(payload);
  const canonicalJson = canonicalStringify(document);
  const hash = await sha256Hex(canonicalJson);
  return { canonicalJson, hash, document };
}

/** Normalize + validate a canonical (or full export) JSON for import. */
export function parseImportDocument(raw: unknown): {
  event: string;
  totalNumber: number;
  sequence: Array<{
    order: number;
    type: string;
    prizeId?: number;
    prizeName?: string;
  }>;
} {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("JSON 必须是对象");
  }

  const document = buildHashDocument(raw);

  if (!Number.isInteger(document.totalNumber) || document.totalNumber < 1) {
    throw new Error("无效的 totalNumber");
  }

  if (document.sequence.length !== document.totalNumber) {
    throw new Error(
      `sequence 长度（${document.sequence.length}）与 totalNumber（${document.totalNumber}）不一致`,
    );
  }

  const seen = new Set<number>();
  for (const item of document.sequence) {
    if (
      !Number.isInteger(item.order) ||
      item.order < 1 ||
      item.order > document.totalNumber
    ) {
      throw new Error(`无效的 order：${item.order}`);
    }
    if (seen.has(item.order)) {
      throw new Error(`重复的 order：${item.order}`);
    }
    seen.add(item.order);

    if (item.type === "prize") {
      if (
        item.prizeId === undefined ||
        !Number.isInteger(item.prizeId) ||
        item.prizeId < 1
      ) {
        throw new Error(`序号 ${item.order} 缺少有效 prizeId`);
      }
    } else if (item.type !== "thank_you") {
      throw new Error(`无效的 type：${item.type}（序号 ${item.order}）`);
    }
  }

  if (seen.size !== document.totalNumber) {
    throw new Error("sequence 缺少部分序号");
  }

  return document;
}

export function downloadTextFile(
  filename: string,
  content: string,
  mime = "application/json;charset=utf-8",
) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
