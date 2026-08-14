import { C, bar, callout, footer, page, pill, rect, text } from "./common.mjs";

export async function slide03(presentation, ctx) {
  const slide = presentation.slides.add();
  page(
    ctx,
    slide,
    3,
    "Direct comparison",
    "真正拉开吞吐的，是混合负载下的有效命中率",
    "以下全部是 linux_accel 相对 BMC；不拿 nohook 的大倍数替代竞品结论。",
  );

  rect(ctx, slide, 58, 184, 758, 420, C.white, "s3-chart-panel", C.line, 1);
  text(ctx, slide, "QPS uplift vs. BMC", 82, 207, 310, 28, {
    fontSize: 17,
    color: C.ink,
    bold: true,
    name: "s3-chart-heading",
  });
  text(ctx, slide, "0", 302, 245, 30, 20, { fontSize: 10, color: C.muted, name: "s3-axis-zero" });
  text(ctx, slide, "35%", 698, 245, 52, 20, {
    fontSize: 10,
    color: C.muted,
    align: "right",
    name: "s3-axis-max",
  });
  bar(ctx, slide, "paper-scaled mixed", 23.39, 35, 82, 284, 670, {
    display: "+23.39%",
    fill: C.cyan,
    name: "s3-paper-mixed",
  });
  bar(ctx, slide, "same-slot pressure", 21.30, 35, 82, 340, 670, {
    display: "+21.30%",
    fill: C.mint,
    name: "s3-slot-pressure",
  });
  bar(ctx, slide, "OpenStack cross-compute", 32.07, 35, 82, 396, 670, {
    display: "+32.07%",
    fill: C.cyan,
    name: "s3-openstack-mixed",
  });
  bar(ctx, slide, "100% hot hit", 3.19, 35, 82, 452, 670, {
    display: "+3.19%",
    fill: C.slate,
    name: "s3-hot-hit",
  });
  bar(ctx, slide, "100% miss/pass", 0.62, 35, 82, 508, 670, {
    display: "+0.62%",
    fill: C.slate,
    name: "s3-all-miss",
  });
  text(ctx, slide, "netns unless marked OpenStack · 6-run median", 82, 565, 430, 20, {
    fontSize: 10,
    color: C.muted,
    name: "s3-chart-note",
  });

  callout(
    ctx,
    slide,
    "纯命中只领先 3.19%",
    "双方都是 100% XDP_TX 时，核心单包路径接近。不能宣称我们的 XDP 指令路径快一个数量级。",
    850,
    184,
    368,
    132,
    { fill: C.coralSoft, accent: C.coral, name: "s3-hit-boundary" },
  );
  callout(
    ctx,
    slide,
    "混合流量多卸载 12–14 pp",
    "exact key 避免 direct-mapped slot 冲突，更多热点不再回落 userspace，因此吞吐提升被放大。",
    850,
    336,
    368,
    132,
    { fill: C.mintSoft, accent: C.mint, name: "s3-offload-proof" },
  );
  pill(ctx, slide, "优势来源：cache organization", 850, 490, 368, {
    fill: C.ink,
    color: C.white,
    fontSize: 16,
    name: "s3-answer-pill",
  });
  text(ctx, slide, "BMC: FNV → direct-mapped slot\nLinux: tenant/interface-scoped exact hash key", 872, 545, 324, 52, {
    fontSize: 13,
    color: C.slate,
    name: "s3-key-contrast",
  });
  footer(ctx, slide, 3, "Primary evidence: BMC formal matrix v2 + final cross-compute OpenStack mixed · 6-run medians");
  return slide;
}
