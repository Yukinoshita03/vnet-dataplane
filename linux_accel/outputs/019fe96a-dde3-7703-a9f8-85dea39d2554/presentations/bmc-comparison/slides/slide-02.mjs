import { C, callout, footer, page, pill, rect, text } from "./common.mjs";

export async function slide02(presentation, ctx) {
  const slide = presentation.slides.add();
  page(
    ctx,
    slide,
    2,
    "Audit correction",
    "旧 pilot 比较了不同容量，+0.16% 必须作废",
    "最终主结论来自对称 ABI/profile，并在真实跨计算节点 TAP 路径复测。",
  );

  rect(ctx, slide, 58, 180, 532, 346, C.coralSoft, "s2-old-panel", C.coral, 1);
  pill(ctx, slide, "INVALIDATED PILOT", 82, 200, 180, {
    fill: C.coral,
    color: C.white,
    name: "s2-old-tag",
  });
  text(ctx, slide, "同一批请求，不同可命中集合", 82, 252, 470, 34, {
    fontSize: 21,
    color: C.ink,
    bold: true,
    name: "s2-old-heading",
  });
  text(ctx, slide, "BMC", 84, 310, 88, 26, {
    fontSize: 16,
    color: C.ink,
    bold: true,
    name: "s2-bmc-label",
  });
  pill(ctx, slide, "4096 slots", 174, 302, 134, { fill: C.white, name: "s2-bmc-slots" });
  text(ctx, slide, "+ TC 动态学习冷 key", 328, 307, 220, 27, {
    fontSize: 14,
    color: C.slate,
    name: "s2-bmc-learn",
  });
  text(ctx, slide, "Linux", 84, 362, 88, 26, {
    fontSize: 16,
    color: C.ink,
    bold: true,
    name: "s2-linux-label",
  });
  pill(ctx, slide, "1024 entries", 174, 354, 134, { fill: C.white, name: "s2-linux-entries" });
  text(ctx, slide, "控制面静态预装", 328, 359, 190, 27, {
    fontSize: 14,
    color: C.slate,
    name: "s2-linux-preload",
  });
  rect(ctx, slide, 84, 414, 460, 1, "#E9B8B2", "s2-old-divider");
  text(ctx, slide, "offload", 84, 435, 90, 24, {
    fontSize: 13,
    color: C.muted,
    name: "s2-offload-label",
  });
  text(ctx, slide, "BMC 85.65%", 176, 433, 145, 27, {
    fontSize: 17,
    color: C.coral,
    bold: true,
    name: "s2-old-bmc-offload",
  });
  text(ctx, slide, "Linux 83.75%", 335, 433, 160, 27, {
    fontSize: 17,
    color: C.ink,
    bold: true,
    name: "s2-old-linux-offload",
  });
  text(ctx, slide, "153,183 vs 153,422 QPS → +0.16%（不可作为结论）", 84, 478, 465, 26, {
    fontSize: 13,
    color: C.coral,
    bold: true,
    name: "s2-invalid-result",
  });

  rect(ctx, slide, 620, 180, 598, 346, C.mintSoft, "s2-new-panel", C.mint, 1);
  pill(ctx, slide, "FINAL CROSS-COMPUTE", 644, 200, 220, {
    fill: C.mint,
    color: C.ink,
    name: "s2-new-tag",
  });
  text(ctx, slide, "同 ABI · 同 workload · 跨计算节点", 644, 252, 520, 34, {
    fontSize: 21,
    color: C.ink,
    bold: true,
    name: "s2-new-heading",
  });
  pill(ctx, slide, "65,536 key population", 646, 300, 220, {
    fill: C.white,
    name: "s2-population",
  });
  text(ctx, slide, "4,096", 882, 303, 68, 28, {
    fontSize: 18,
    color: C.mint,
    bold: true,
    align: "center",
    name: "s2-ratio",
  });
  pill(ctx, slide, "hot keys / cache", 974, 300, 196, {
    fill: C.white,
    name: "s2-equal-cache",
  });
  text(ctx, slide, "BMC", 646, 370, 80, 25, { fontSize: 14, color: C.slate, name: "s2-new-bmc-label" });
  rect(ctx, slide, 728, 373, 314, 18, C.faint, "s2-new-bmc-track");
  rect(ctx, slide, 728, 373, 285, 18, C.slate, "s2-new-bmc-fill");
  text(ctx, slide, "51,547", 1055, 365, 110, 30, {
    fontSize: 18,
    color: C.slate,
    bold: true,
    align: "right",
    name: "s2-new-bmc-qps",
  });
  text(ctx, slide, "Linux", 646, 421, 80, 25, { fontSize: 14, color: C.slate, name: "s2-new-linux-label" });
  rect(ctx, slide, 728, 424, 314, 18, C.faint, "s2-new-linux-track");
  rect(ctx, slide, 728, 424, 314, 18, C.cyan, "s2-new-linux-fill");
  text(ctx, slide, "68,078", 1055, 416, 110, 30, {
    fontSize: 18,
    color: C.cyan,
    bold: true,
    align: "right",
    name: "s2-new-linux-qps",
  });
  pill(ctx, slide, "+32.07% QPS", 646, 470, 174, {
    fill: C.cyan,
    color: C.ink,
    fontSize: 16,
    name: "s2-new-qps-gain",
  });
  text(ctx, slide, "offload Δ +13.674 pp", 842, 475, 220, 26, {
    fontSize: 15,
    color: C.slate,
    bold: true,
    name: "s2-new-offload-gain",
  });

  callout(
    ctx,
    slide,
    "harness 已把这类错误变成 hard fail",
    "运行时读取 BMC BUILD-METADATA；mixed 场景若 BMC slots、Linux preload 与 workload contract 不一致，实验直接拒跑。",
    58,
    548,
    1160,
    92,
    { fill: C.white, accent: C.cyan, name: "s2-hard-fail" },
  );
  footer(ctx, slide, 2, "Evidence: invalidated pilot + final cross-compute OpenStack mixed · 6 repetitions per mode");
  return slide;
}
