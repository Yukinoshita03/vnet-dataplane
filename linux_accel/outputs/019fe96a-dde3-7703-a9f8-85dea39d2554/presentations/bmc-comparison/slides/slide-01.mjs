import { C, FONT, MONO, W, H, metric, pill, rect, text } from "./common.mjs";

export async function slide01(presentation, ctx) {
  const slide = presentation.slides.add();
  rect(ctx, slide, 0, 0, W, H, C.paper, "s1-background");
  rect(ctx, slide, 0, 0, 18, H, C.cyan, "s1-accent");
  rect(ctx, slide, 0, 0, 520, H, C.ink, "s1-left-panel");

  text(ctx, slide, "DIRECT COMPETITOR · NSDI'21 BMC", 62, 48, 420, 24, {
    fontSize: 13,
    color: C.cyan,
    bold: true,
    name: "s1-kicker",
  });
  text(ctx, slide, "OpenStack 下不是\n+0.16%，最终是\n+32.07%", 62, 92, 410, 190, {
    fontSize: 40,
    color: C.white,
    bold: true,
    name: "s1-title",
  });
  text(ctx, slide, "linux_accel vs. Orange BMC\nnode1 VM → TAP → OVS/OVN/Geneve → node2 VM · 6-run median", 64, 298, 410, 72, {
    fontSize: 16,
    color: "#B8C8D7",
    name: "s1-subtitle",
  });

  metric(ctx, slide, "+23.39%", "netns · BMC paper-scaled mixed QPS", 64, 398, 190, {
    color: C.mint,
    valueSize: 30,
    labelColor: "#B8C8D7",
    name: "s1-netns-metric",
  });
  metric(ctx, slide, "+32.07%", "OpenStack TAP · cross-compute mixed QPS", 276, 398, 198, {
    color: C.cyan,
    valueSize: 30,
    labelColor: "#B8C8D7",
    name: "s1-openstack-metric",
  });

  pill(ctx, slide, "207.3M timed requests · 0 failure", 64, 526, 410, {
    fill: C.slate,
    color: C.white,
    fontSize: 14,
    name: "s1-request-pill",
  });
  text(ctx, slide, "BMC@2997145508e0 · Linux 7.0 · Kubernetes OFF", 64, 584, 410, 24, {
    fontSize: 10,
    color: "#7E98AC",
    typeface: MONO,
    name: "s1-runtime-note",
  });

  await ctx.addImage(slide, {
    path: `${ctx.assetDir}/network-fastpath.png`,
    x: 548,
    y: 64,
    width: 684,
    height: 455,
    fit: "contain",
    alt: "Multi-path network acceleration illustration supplied for this deck",
    name: "s1-fastpath-image",
  });
  text(ctx, slide, "真实跨计算节点也保持优势", 570, 542, 620, 34, {
    fontSize: 22,
    color: C.ink,
    bold: true,
    name: "s1-bottom-claim",
  });
  text(ctx, slide, "混合热点下多保住 12–14 pp 有效卸载率；p50/p95/p99 同时更低。", 570, 582, 620, 34, {
    fontSize: 16,
    color: C.muted,
    name: "s1-bottom-proof",
  });
  text(ctx, slide, "01", 1170, 674, 50, 20, {
    fontSize: 11,
    color: C.muted,
    typeface: MONO,
    align: "right",
    name: "s1-page",
  });
  return slide;
}
