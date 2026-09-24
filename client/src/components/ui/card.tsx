import type { HTMLAttributes } from "react";
import { cn } from "@/lib/utils";

export function Card({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        "rounded-xl border border-navy/10 bg-white p-5 text-ink shadow-sm",
        className,
      )}
      {...props}
    />
  );
}
