import { C, FONT, MONO, W, H, metric, pill, rect, text } from "./common.mjs";

export async function slide07(presentation, ctx) {
  const slide = presentation.slides.add();
  rect(ctx, slide, 0, 0, W, H, C.ink, "s7-background");
  rect(ctx, slide, 0, 0, 14, H, C.cyan, "s7-accent");
  text(ctx, slide, "ANSWER", 62, 45, 260, 24, {
    fontSize: 13,
    color: C.cyan,
    bold: true,
    name: "s7-kicker",
  });
  text(ctx, slide, "强于 BMC 的是体系，\n不是一句“大倍数”", 62, 83, 650, 112, {
    fontSize: 42,
    color: C.white,
    bold: true,
    name: "s7-title",
  });

  text(ctx, slide, "01", 64, 250, 48, 40, {
    fontSize: 27,
    color: C.cyan,
    bold: true,
    typeface: MONO,
    name: "s7-claim1-number",
  });
  text(ctx, slide, "混合热点更稳", 128, 247, 260, 32, {
    fontSize: 21,
    color: C.white,
    bold: true,
    name: "s7-claim1-title",
  });
  text(ctx, slide, "netns +21–23%；OpenStack +32.07%；核心来自 +12–14 pp 有效卸载率。", 128, 282, 580, 44, {
    fontSize: 14,
    color: "#B8C8D7",
    name: "s7-claim1-body",
  });

  text(ctx, slide, "02", 64, 360, 48, 40, {
    fontSize: 27,
    color: C.mint,
    bold: true,
    typeface: MONO,
    name: "s7-claim2-number",
  });
  text(ctx, slide, "OpenStack 证据完整", 128, 357, 300, 32, {
    fontSize: 21,
    color: C.white,
    bold: true,
    name: "s7-claim2-title",
  });
  text(ctx, slide, "同 ABI、同 workload、跨计算节点，QPS 与 p50/p95/p99 同时更好，且零错误。", 128, 392, 580, 44, {
    fontSize: 14,
    color: "#B8C8D7",
    name: "s7-claim2-body",
  });

  text(ctx, slide, "03", 64, 470, 48, 40, {
    fontSize: 27,
    color: C.amber,
    bold: true,
    typeface: MONO,
    name: "s7-claim3-number",
  });
  text(ctx, slide, "工程覆盖更广", 128, 467, 280, 32, {
    fontSize: 21,
    color: C.white,
    bold: true,
    name: "s7-claim3-title",
  });
  text(ctx, slide, "从单协议 cache 扩展到 DNS / ARP / UDP / gRPC / LDAP / DHCP，并具备 owner-safe 部署与恢复。", 128, 502, 580, 44, {
    fontSize: 14,
    color: "#B8C8D7",
    name: "s7-claim3-body",
  });

  rect(ctx, slide, 760, 60, 458, 510, C.white, "s7-ledger-panel");
  text(ctx, slide, "EVIDENCE LEDGER", 790, 88, 360, 24, {
    fontSize: 12,
    color: C.cyan,
    bold: true,
    name: "s7-ledger-kicker",
  });
  metric(ctx, slide, "207.3M", "all timed requests", 790, 132, 180, {
    color: C.ink,
    valueSize: 32,
    name: "s7-requests",
  });
  metric(ctx, slide, "0", "failure / checksum / softnet drop", 1000, 132, 180, {
    color: C.cyan,
    valueSize: 32,
    name: "s7-errors",
  });
  rect(ctx, slide, 790, 244, 398, 1, C.line, "s7-ledger-divider1");
  text(ctx, slide, "Pinned competitor", 790, 267, 164, 24, {
    fontSize: 13,
    color: C.muted,
    name: "s7-pinned-label",
  });
  text(ctx, slide, "BMC 2997145508e0", 966, 265, 222, 26, {
    fontSize: 13,
    color: C.ink,
    bold: true,
    typeface: MONO,
    align: "right",
    name: "s7-pinned-value",
  });
  text(ctx, slide, "Runtime", 790, 312, 164, 24, { fontSize: 13, color: C.muted, name: "s7-runtime-label" });
  text(ctx, slide, "Linux 7.0 · K8s OFF", 966, 310, 222, 26, {
    fontSize: 13,
    color: C.ink,
    bold: true,
    typeface: MONO,
    align: "right",
    name: "s7-runtime-value",
  });
  text(ctx, slide, "Cleanup", 790, 357, 164, 24, { fontSize: 13, color: C.muted, name: "s7-cleanup-label" });
  text(ctx, slide, "hooks empty · qdisc noqueue", 966, 355, 222, 26, {
    fontSize: 12,
    color: C.ink,
    bold: true,
    typeface: MONO,
    align: "right",
    name: "s7-cleanup-value",
  });
  rect(ctx, slide, 790, 410, 398, 1, C.line, "s7-ledger-divider2");
  text(ctx, slide, "尚未覆盖", 790, 435, 164, 24, {
    fontSize: 13,
    color: C.coral,
    bold: true,
    name: "s7-gap-label",
  });
  text(ctx, slide, "physical NIC native XDP\nstock r8169 on node1", 966, 431, 222, 52, {
    fontSize: 13,
    color: C.slate,
    align: "right",
    name: "s7-gap-value",
  });
  pill(ctx, slide, "下一步：OOB rebind + watchdog native", 790, 505, 398, {
    fill: C.coralSoft,
    color: C.coral,
    fontSize: 14,
    name: "s7-next-step",
  });

  rect(ctx, slide, 62, 601, 1156, 1, C.slate, "s7-footer-line");
  text(ctx, slide, "结论边界清楚，才是可信的性能优势。", 64, 627, 760, 32, {
    fontSize: 20,
    color: C.white,
    bold: true,
    name: "s7-closing-line",
  });
  text(ctx, slide, "07", 1168, 674, 50, 20, {
    fontSize: 11,
    color: "#7E98AC",
    typeface: MONO,
    align: "right",
    name: "s7-page",
  });
  return slide;
}
