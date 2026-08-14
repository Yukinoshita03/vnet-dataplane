import { C, bar, callout, footer, metric, page, pill, rect, text } from "./common.mjs";

function pathNode(ctx, slide, label, x, width, fill, name) {
  return text(ctx, slide, label, x, 190, width, 62, {
    fontSize: 14,
    color: C.ink,
    bold: true,
    align: "center",
    valign: "middle",
    fill,
    lineFill: C.line,
    lineWidth: 1,
    name,
  });
}

export async function slide05(presentation, ctx) {
  const slide = presentation.slides.add();
  page(
    ctx,
    slide,
    5,
    "OpenStack proof",
    "跨计算节点 mixed 下，吞吐与三档延迟同时优于 BMC",
    "路径真实穿过 client VM/TAP、OVS/OVN/Geneve 与 backend VM；6-run median。",
  );

  pathNode(ctx, slide, "VM ens3\nvirtio", 58, 176, C.white, "s5-path-vm");
  text(ctx, slide, "→", 240, 203, 38, 30, { fontSize: 22, color: C.muted, align: "center", name: "s5-path-arrow1" });
  pathNode(ctx, slide, "host TAP\ngeneric XDP", 282, 210, C.cyanSoft, "s5-path-tap");
  text(ctx, slide, "→", 498, 203, 38, 30, { fontSize: 22, color: C.muted, align: "center", name: "s5-path-arrow2" });
  pathNode(ctx, slide, "OVS br-int\nOVN", 540, 196, C.white, "s5-path-ovs");
  text(ctx, slide, "→", 742, 203, 38, 30, { fontSize: 22, color: C.muted, align: "center", name: "s5-path-arrow3" });
  pathNode(ctx, slide, "Geneve\nbackend VM node2", 784, 266, C.faint, "s5-path-backend");

  rect(ctx, slide, 58, 288, 650, 326, C.white, "s5-qps-panel", C.line, 1);
  text(ctx, slide, "Mixed QPS · 6-run median", 82, 312, 300, 28, {
    fontSize: 17,
    color: C.ink,
    bold: true,
    name: "s5-qps-heading",
  });
  bar(ctx, slide, "nohook", 23288, 80000, 82, 370, 580, {
    display: "23,288",
    fill: C.slate,
    name: "s5-nohook-bar",
  });
  bar(ctx, slide, "BMC", 51547, 80000, 82, 430, 580, {
    display: "51,547",
    fill: C.amber,
    name: "s5-bmc-bar",
  });
  bar(ctx, slide, "linux_accel", 68078, 80000, 82, 490, 580, {
    display: "68,078",
    fill: C.cyan,
    boldLabel: true,
    name: "s5-linux-bar",
  });
  pill(ctx, slide, "Linux / BMC = 1.321x", 82, 548, 246, {
    fill: C.cyan,
    color: C.ink,
    name: "s5-qps-ratio",
  });
  text(ctx, slide, "offload 75.080% vs 61.406%", 346, 553, 316, 26, {
    fontSize: 14,
    color: C.slate,
    bold: true,
    align: "right",
    name: "s5-offload-result",
  });

  rect(ctx, slide, 738, 288, 480, 326, C.ink, "s5-latency-panel");
  text(ctx, slide, "Latency reduction vs. BMC", 766, 312, 400, 28, {
    fontSize: 17,
    color: C.white,
    bold: true,
    name: "s5-latency-heading",
  });
  metric(ctx, slide, "−2.47%", "p50 · 11.099 → 10.825 us", 766, 366, 195, {
    color: C.mint,
    valueSize: 29,
    labelColor: "#B8C8D7",
    labelSize: 12,
    name: "s5-p50",
  });
  metric(ctx, slide, "−1.51%", "p95 · 90.236 → 88.874 us", 986, 366, 204, {
    color: C.mint,
    valueSize: 29,
    labelColor: "#B8C8D7",
    labelSize: 12,
    name: "s5-p95",
  });
  metric(ctx, slide, "−1.48%", "p99 · 97.212 → 95.769 us", 766, 486, 220, {
    color: C.cyan,
    valueSize: 29,
    labelColor: "#B8C8D7",
    labelSize: 12,
    name: "s5-p99",
  });
  pill(ctx, slide, "0 failure · 0 checksum error · 0 softnet drop", 986, 493, 204, {
    fill: C.slate,
    color: C.white,
    height: 58,
    fontSize: 11,
    name: "s5-zero-error",
  });
  text(ctx, slide, "Owner-checked cleanup: TAP qdisc restored to noqueue; no test BPF hooks remained.", 766, 580, 424, 24, {
    fontSize: 10,
    color: "#8DA4B7",
    name: "s5-cleanup-note",
  });
  footer(ctx, slide, 5, "Artifact: all-comparisons/20260814-node1-v1/openstack-bmc-formal-v1 · 6 runs");
  return slide;
}
