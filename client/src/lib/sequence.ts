/** Format: "12, 13, 42, 45, 18" — this exact string is what we SHA-256. */

export function numbersToText(numbers: number[]): string {
  return numbers.join(", ");
}

export function parseNumbersText(text: string): number[] {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((s) => {
      const n = Number(s);
      if (!Number.isInteger(n)) {
        throw new Error(`无效的号码：${s}`);
      }
      return n;
    });
}

export async function sha256Hex(text: string): Promise<string> {
  const data = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export type SequencePayload = {
  totalNumber: number;
  numbers: number[];
  numbersText: string;
  sequenceLocked?: boolean;
  sequenceHash?: string | null;
  sequenceLockedAt?: string | null;
};

/** Normalize API / file payload into numbers + canonical text. */
export function normalizeSequencePayload(payload: unknown): SequencePayload {
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("无效的序列数据");
  }
  const body = payload as Record<string, unknown>;

  let numbers: number[];
  if (Array.isArray(body.numbers)) {
    numbers = body.numbers.map((n, i) => {
      const v = Number(n);
      if (!Number.isInteger(v)) {
        throw new Error(`无效的号码（下标 ${i}）`);
      }
      return v;
    });
  } else if (typeof body.numbersText === "string") {
    numbers = parseNumbersText(body.numbersText);
  } else if (typeof body.sequenceNumbers === "string" && body.sequenceNumbers) {
    numbers = parseNumbersText(body.sequenceNumbers);
  } else {
    throw new Error("缺少 numbers / numbersText");
  }

  const totalNumber = Number(body.totalNumber ?? numbers.length);
  if (!Number.isInteger(totalNumber) || totalNumber < 1) {
    throw new Error("无效的 totalNumber");
  }

  if (numbers.length !== totalNumber) {
    throw new Error(
      `numbers 长度（${numbers.length}）与 totalNumber（${totalNumber}）不一致`,
    );
  }

  const seen = new Set<number>();
  for (const n of numbers) {
    if (n < 1 || n > totalNumber) {
      throw new Error(`无效的号码：${n}`);
    }
    if (seen.has(n)) {
      throw new Error(`重复的号码：${n}`);
    }
    seen.add(n);
  }

  if (seen.size !== totalNumber) {
    throw new Error("号码列表不是 1..N 的完整排列");
  }

  return {
    totalNumber,
    numbers,
    numbersText: numbersToText(numbers),
    sequenceLocked: Boolean(body.sequenceLocked),
    sequenceHash:
      typeof body.sequenceHash === "string" ? body.sequenceHash : null,
    sequenceLockedAt:
      typeof body.sequenceLockedAt === "string" ? body.sequenceLockedAt : null,
  };
}

export async function hashNumbersText(
  numbersText: string,
): Promise<{ numbersText: string; hash: string }> {
  const hash = await sha256Hex(numbersText);
  return { numbersText, hash };
}

export async function hashSequencePayload(
  payload: unknown,
): Promise<{ numbersText: string; hash: string; document: SequencePayload }> {
  const document = normalizeSequencePayload(payload);
  const { hash } = await hashNumbersText(document.numbersText);
  return { numbersText: document.numbersText, hash, document };
}

/** Accept export JSON, plain text list, or { numbers / numbersText }. */
export function parseImportDocument(raw: unknown): {
  totalNumber: number;
  numbers: number[];
  numbersText: string;
} {
  if (typeof raw === "string") {
    const numbers = parseNumbersText(raw);
    return {
      totalNumber: numbers.length,
      numbers,
      numbersText: numbersToText(numbers),
    };
  }
  return normalizeSequencePayload(raw);
}

export function downloadTextFile(
  filename: string,
  content: string,
  mime = "text/plain;charset=utf-8",
) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
