import { useEffect, useMemo, useRef, useState } from "react";
import type { Prize } from "@/lib/types";
import { publicImageUrl } from "@/lib/api";
import { cn } from "@/lib/utils";

const SEGMENT_COLORS = [
  "#003660",
  "#0b4f7a",
  "#156089",
  "#1f5570",
  "#0a3d5c",
  "#184e6e",
  "#225a7a",
];

/** Spin duration in ms — keep timeout in sync */
const SPIN_MS = 9000;

export interface WheelProps {
  prizes: Prize[];
  spinning: boolean;
  /** Index into wheel segments (prizes + 谢谢参与 at end) to land on */
  targetIndex: number | null;
  onSpinEnd?: () => void;
  className?: string;
}

function normalizeDeg(deg: number): number {
  return ((deg % 360) + 360) % 360;
}

export function LotteryWheel({
  prizes,
  spinning,
  targetIndex,
  onSpinEnd,
  className,
}: WheelProps) {
  const segments = useMemo(() => {
    const items: Array<{
      key: string;
      label: string;
      image: string | null;
      isThankYou: boolean;
    }> = prizes.map((p) => ({
      key: `prize-${p.id}`,
      label: p.name,
      image: publicImageUrl(p.imagePath),
      isThankYou: false,
    }));
    items.push({
      key: "thank-you",
      label: "谢谢参与",
      image: null,
      isThankYou: true,
    });
    return items;
  }, [prizes]);

  const n = Math.max(segments.length, 1);
  const anglePer = 360 / n;
  const [rotation, setRotation] = useState(0);
  const rotationRef = useRef(0);
  const spinningRef = useRef(false);
  const onSpinEndRef = useRef(onSpinEnd);
  onSpinEndRef.current = onSpinEnd;

  useEffect(() => {
    rotationRef.current = rotation;
  }, [rotation]);

  useEffect(() => {
    if (!spinning || targetIndex === null || spinningRef.current) return;
    spinningRef.current = true;

    const idx = ((targetIndex % n) + n) % n;
    // 0° = top, clockwise (CSS conic-gradient + rotate).
    // Segment i: [i*anglePer, (i+1)*anglePer), center at midpoint.
    // rotate(R) moves a wheel mark at θ to screen angle θ+R.
    // For center under top pointer: segmentCenter + R ≡ 0 (mod 360).
    const segmentCenter = idx * anglePer + anglePer / 2;
    const targetMod = normalizeDeg(-segmentCenter);

    const currentMod = normalizeDeg(rotationRef.current);
    let delta = normalizeDeg(targetMod - currentMod);
    if (delta < 1) delta += 360;

    const extraTurns = 7 + Math.floor(Math.random() * 3); // 7–9 turns
    const next = rotationRef.current + extraTurns * 360 + delta;

    let raf2 = 0;
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => {
        setRotation(next);
        rotationRef.current = next;
      });
    });

    const timer = window.setTimeout(() => {
      // Exact modulo snap so we never rest on a divider
      const exact = next - normalizeDeg(next) + targetMod;
      setRotation(exact);
      rotationRef.current = exact;
      spinningRef.current = false;
      onSpinEndRef.current?.();
    }, SPIN_MS + 100);

    return () => {
      cancelAnimationFrame(raf1);
      cancelAnimationFrame(raf2);
      window.clearTimeout(timer);
    };
  }, [spinning, targetIndex, n, anglePer]);

  const gradient = useMemo(() => {
    if (n === 0) return "#003660";
    const parts = segments.map((seg, i) => {
      const color = seg.isThankYou
        ? "#6b7280"
        : SEGMENT_COLORS[i % SEGMENT_COLORS.length]!;
      const start = i * anglePer;
      const end = (i + 1) * anglePer;
      return `${color} ${start}deg ${end}deg`;
    });
    return `conic-gradient(${parts.join(", ")})`;
  }, [segments, n, anglePer]);

  return (
    <div
      className={cn(
        "relative mx-auto w-full max-w-[min(92vw,560px)] pt-5",
        className,
      )}
    >
      <div
        className="absolute left-1/2 top-0 z-30 -translate-x-1/2"
        aria-hidden
      >
        <div className="flex flex-col items-center">
          <div className="h-3.5 w-3.5 rounded-full bg-gold shadow-[0_0_12px_rgba(212,160,23,0.8)]" />
          <div className="h-0 w-0 border-l-[16px] border-r-[16px] border-t-[28px] border-l-transparent border-r-transparent border-t-gold drop-shadow-lg" />
        </div>
      </div>

      <div className="relative rounded-full bg-gradient-to-b from-gold-soft via-gold to-[#a67c00] p-[3px] shadow-[0_24px_60px_rgba(0,26,51,0.4)]">
        <div className="relative rounded-full bg-navy-deep p-2.5">
          <div
            className="relative aspect-square overflow-hidden rounded-full border-[3px] border-gold/80"
            style={{
              background: gradient,
              transform: `rotate(${rotation}deg)`,
              transition: spinning
                ? `transform ${SPIN_MS}ms cubic-bezier(0.12, 0.82, 0.08, 1)`
                : "none",
            }}
          >
            {segments.map((_, i) => (
              <div
                key={`div-${i}`}
                className="pointer-events-none absolute left-1/2 top-0 z-[1] h-1/2 w-[2px] bg-gold/40"
                style={{
                  transform: `rotate(${i * anglePer}deg)`,
                  transformOrigin: "50% 100%",
                  marginLeft: "-1px",
                }}
              />
            ))}

            {segments.map((seg, i) => {
              const rot = i * anglePer + anglePer / 2;
              return (
                <div
                  key={seg.key}
                  className="pointer-events-none absolute inset-0"
                  style={{ transform: `rotate(${rot}deg)` }}
                >
                  <div className="absolute left-1/2 top-[7%] flex w-[42%] -translate-x-1/2 flex-col items-center gap-1.5 text-center">
                    <span className="font-sans line-clamp-2 text-sm font-bold leading-snug text-white drop-shadow-[0_1px_3px_rgba(0,0,0,0.85)] sm:text-base">
                      {seg.label}
                    </span>
                    {seg.image ? (
                      <img
                        src={seg.image}
                        alt=""
                        className="h-12 w-12 rounded-md object-cover shadow-md ring-2 ring-white/50 sm:h-14 sm:w-14"
                      />
                    ) : seg.isThankYou ? (
                      <span className="flex h-10 w-10 items-center justify-center rounded-md bg-white/15 font-sans text-lg text-white/90 sm:h-12 sm:w-12">
                        ✦
                      </span>
                    ) : null}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Fixed hub — does not rotate with the disc */}
          <div className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center">
            <div className="flex h-[17%] w-[17%] min-h-16 min-w-16 items-center justify-center rounded-full border-[3px] border-gold bg-gradient-to-b from-navy to-navy-deep shadow-[inset_0_2px_8px_rgba(0,0,0,0.45),0_4px_16px_rgba(0,0,0,0.35)]">
              <span className="font-sans text-xs font-bold tracking-wider text-gold-soft sm:text-sm">
                CSSA
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export function resultToSegmentIndex(
  prizes: Prize[],
  prize: Prize | null,
  thankYou: boolean,
): number {
  if (thankYou || !prize) return prizes.length;
  const idx = prizes.findIndex((p) => p.id === prize.id);
  return idx >= 0 ? idx : prizes.length;
}
