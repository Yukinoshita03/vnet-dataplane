import { C, footer, page, pill, rect, text } from "./common.mjs";

const rows = [
  { protocol: "DNS", baseline: "Xpress", qps: "1.180x", p99: "capacity metric", note: "Radar mix; +17.95% 1% loss capacity; client-limited lower bound", color: C.cyanSoft },
  { protocol: "ARP", baseline: "kernel ARP", qps: "1.840x", p99: "1.237x better", note: "configured target; server capture = 0", color: C.mintSoft },
  { protocol: "UDP", baseline: "userspace", qps: "11.276x", p99: "6.829x better", note: "exact, deterministic, side-effect-free exchange", color: C.cyanSoft },
  { protocol: "LDAP", baseline: "userspace proxy", qps: "0.882x", p99: "0.877x", note: "slower; proxy CPU 14.02 s → 0.02 s", color: C.amberSoft },
  { protocol: "gRPC", baseline: "delayed demo", qps: "12.645x", p99: "12.030x better", note: "300 us simulated backend; mechanism result", color: C.cyanSoft },
  { protocol: "DHCP", baseline: "relay semantics", qps: "—", p99: "—", note: "stateful forwarding; correctness gate only", color: C.faint },
];

export async function slide06(presentation, ctx) {
  const slide = presentation.slides.add();
  page(
    ctx,
    slide,
    6,
    "Protocol portfolio",
    "优势不止 DNS，但每个协议必须用对 baseline",
    "BMC 只实现 Memcached；跨协议不能硬凑一个“总体加速比”，更不能把不同语义的倍数平均。",
  );

  const x = 58;
  const y = 182;
  const widths = [118, 176, 132, 178, 500];
  const labels = ["PROTOCOL", "BASELINE", "QPS RATIO", "P99", "BOUNDARY / INTERPRETATION"];
  let cursor = x;
  for (let i = 0; i < labels.length; i += 1) {
    text(ctx, slide, labels[i], cursor, y, widths[i], 34, {
      fontSize: 11,
      color: C.white,
      bold: true,
      align: i >= 2 && i <= 3 ? "center" : "left",
      valign: "middle",
      fill: C.ink,
      insets: { left: 10, right: 10, top: 2, bottom: 2 },
      name: `s6-header-${i}`,
    });
    cursor += widths[i];
  }

  rows.forEach((row, index) => {
    const rowY = y + 42 + index * 62;
    rect(ctx, slide, x, rowY, 1104, 58, index % 2 === 0 ? C.white : "#F9FBFD", `s6-row-${index}`, C.line, 1);
    text(ctx, slide, row.protocol, x + 10, rowY + 9, widths[0] - 20, 32, {
      fontSize: 17,
      color: C.ink,
      bold: true,
      valign: "middle",
      name: `s6-protocol-${index}`,
    });
    text(ctx, slide, row.baseline, x + widths[0] + 10, rowY + 9, widths[1] - 20, 32, {
      fontSize: 13,
      color: C.slate,
      valign: "middle",
      name: `s6-baseline-${index}`,
    });
    pill(ctx, slide, row.qps, x + widths[0] + widths[1] + 14, rowY + 9, widths[2] - 28, {
      fill: row.color,
      color: row.protocol === "LDAP" ? "#8A5A00" : C.ink,
      height: 34,
      fontSize: 14,
      name: `s6-qps-${index}`,
    });
    text(ctx, slide, row.p99, x + widths[0] + widths[1] + widths[2] + 6, rowY + 9, widths[3] - 12, 34, {
      fontSize: 12,
      color: row.protocol === "LDAP" ? "#8A5A00" : C.slate,
      bold: row.protocol !== "DHCP",
      align: "center",
      valign: "middle",
      name: `s6-p99-${index}`,
    });
    text(ctx, slide, row.note, x + widths[0] + widths[1] + widths[2] + widths[3] + 10, rowY + 8, widths[4] - 20, 36, {
      fontSize: 12,
      color: C.muted,
      valign: "middle",
      name: `s6-note-${index}`,
    });
  });

  pill(ctx, slide, "LDAP 不是 latency win，而是 CPU offload", 58, 608, 392, {
    fill: C.amberSoft,
    color: "#8A5A00",
    name: "s6-ldap-boundary",
  });
  text(ctx, slide, "其余协议的结果也只在各自的流量与语义边界内成立。", 478, 614, 684, 25, {
    fontSize: 13,
    color: C.muted,
    align: "right",
    name: "s6-boundary-note",
  });
  footer(ctx, slide, 6, "Protocol matrix: 6-run medians · current correctness gates passed · Kubernetes remained inactive");
  return slide;
}
