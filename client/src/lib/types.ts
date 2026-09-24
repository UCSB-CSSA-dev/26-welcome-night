export type LotteryStatus = "setup" | "running" | "finished";

export interface LotteryConfig {
  totalNumber: number;
  currentCursor: number;
  status: LotteryStatus;
  updatedAt: string;
  sequenceLocked?: boolean;
  sequenceHash?: string | null;
  sequenceLockedAt?: string | null;
}

export interface Prize {
  id: number;
  name: string;
  description: string;
  quantity: number;
  imagePath: string | null;
  sortOrder: number;
}

export interface HistoryItem {
  orderNumber: number;
  prizeId: number | null;
  prizeName: string | null;
  sessionId: string | null;
  createdAt: string;
}

export interface LotteryState {
  config: LotteryConfig;
  prizes: Prize[];
  history: HistoryItem[];
  remainingPrizes: number;
  drawnPrizes: number;
}

export interface DeviceSession {
  id: string;
  code: string;
  approved: boolean;
  label: string;
  createdAt: string;
}

export interface DrawResult {
  orderNumber: number;
  thankYou: boolean;
  finished: boolean;
  prize: Prize | null;
}

const SESSION_KEY = "welcome_night_session_id";
const ADMIN_TOKEN_KEY = "welcome_night_admin_token";

export function loadSessionId(): string | null {
  return localStorage.getItem(SESSION_KEY);
}

export function saveSessionId(id: string) {
  localStorage.setItem(SESSION_KEY, id);
}

export function clearSessionId() {
  localStorage.removeItem(SESSION_KEY);
}

export function loadAdminToken(): string | null {
  return localStorage.getItem(ADMIN_TOKEN_KEY);
}

export function saveAdminToken(token: string) {
  localStorage.setItem(ADMIN_TOKEN_KEY, token);
}

export function clearAdminToken() {
  localStorage.removeItem(ADMIN_TOKEN_KEY);
}
