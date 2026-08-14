import { C, footer, page, pill, rect, text } from "./common.mjs";

function node(ctx, slide, value, x, y, width, fill, name, color = C.ink) {
  return text(ctx, slide, value, x, y, width, 52, {
    fontSize: 14,
    color,
    bold: true,
    align: "center",
    valign: "middle",
    fill,
    lineFill: C.line,
    lineWidth: 1,
    insets: { left: 8, right: 8, top: 4, bottom: 4 },
    name,
  });
}

export async function slide04(presentation, ctx) {
  const slide = presentation.slides.add();
  page(
    ctx,
    slide,
    4,
    "Architecture",
    "BMC 用数据面学习换自动化，我们用精确控制面换隔离与确定性",
    "两者都能在 ingress XDP 命中后 XDP_TX；不同的是 cache state machine 与 key ownership。",
  );

  rect(ctx, slide, 58, 180, 548, 382, C.white, "s4-bmc-panel", C.line, 1);
  pill(ctx, slide, "BMC · Memcached UDP GET", 82, 201, 260, {
    fill: C.slate,
    color: C.white,
    name: "s4-bmc-tag",
  });
  node(ctx, slide, "request packet", 84, 266, 122, C.faint, "s4-bmc-request");
  text(ctx, slide, "→", 214, 278, 30, 28, { fontSize: 24, color: C.muted, align: "center", name: "s4-bmc-arrow1" });
  node(ctx, slide, "XDP ingress\nFNV → slot", 250, 266, 148, C.cyanSoft, "s4-bmc-xdp");
  text(ctx, slide, "→", 406, 278, 30, 28, { fontSize: 24, color: C.muted, align: "center", name: "s4-bmc-arrow2" });
  node(ctx, slide, "hit: XDP_TX\nmiss: PASS", 442, 266, 136, C.mintSoft, "s4-bmc-outcome");

  node(ctx, slide, "userspace backend", 84, 382, 148, C.coralSoft, "s4-bmc-backend");
  text(ctx, slide, "response →", 244, 393, 90, 28, {
    fontSize: 13,
    color: C.muted,
    align: "center",
    name: "s4-bmc-response-arrow",
  });
  node(ctx, slide, "TC egress\nlearn response", 342, 382, 150, C.amberSoft, "s4-bmc-tc");
  text(ctx, slide, "↖ fills slot", 494, 396, 86, 24, {
    fontSize: 12,
    color: C.amber,
    bold: true,
    name: "s4-bmc-learn-arrow",
  });
  text(ctx, slide, "TCP SET parser 触发受限失效", 84, 484, 470, 30, {
    fontSize: 14,
    color: C.slate,
    name: "s4-bmc-invalidation",
  });
  text(ctx, slide, "优点：从真实 response 动态学习", 84, 520, 470, 24, {
    fontSize: 13,
    color: C.muted,
    name: "s4-bmc-pro",
  });

  rect(ctx, slide, 636, 180, 582, 382, C.white, "s4-linux-panel", C.line, 1);
  pill(ctx, slide, "linux_accel · protocol-aware fast path", 660, 201, 324, {
    fill: C.cyan,
    color: C.ink,
    name: "s4-linux-tag",
  });
  node(ctx, slide, "request packet", 660, 266, 122, C.faint, "s4-linux-request");
  text(ctx, slide, "→", 790, 278, 30, 28, { fontSize: 24, color: C.muted, align: "center", name: "s4-linux-arrow1" });
  node(ctx, slide, "XDP ingress\nexact tuple", 826, 266, 148, C.cyanSoft, "s4-linux-xdp");
  text(ctx, slide, "→", 982, 278, 30, 28, { fontSize: 24, color: C.muted, align: "center", name: "s4-linux-arrow2" });
  node(ctx, slide, "hit: XDP_TX\nmiss: PASS", 1018, 266, 170, C.mintSoft, "s4-linux-outcome");

  node(ctx, slide, "policy / interface feed", 660, 382, 176, C.amberSoft, "s4-linux-policy");
  text(ctx, slide, "→", 844, 394, 30, 28, { fontSize: 24, color: C.muted, align: "center", name: "s4-linux-arrow3" });
  node(ctx, slide, "owner-scoped map\npreload + expiry", 880, 382, 170, C.cyanSoft, "s4-linux-map");
  text(ctx, slide, "→ lookup", 1058, 395, 108, 26, {
    fontSize: 13,
    color: C.cyan,
    bold: true,
    name: "s4-linux-lookup-arrow",
  });
  text(ctx, slide, "key = ifindex + service IP/port + request bytes", 660, 484, 520, 30, {
    fontSize: 14,
    color: C.slate,
    name: "s4-linux-key",
  });
  text(ctx, slide, "优点：tenant/interface 隔离、TTL、策略可审计", 660, 520, 520, 24, {
    fontSize: 13,
    color: C.muted,
    name: "s4-linux-pro",
  });

  rect(ctx, slide, 58, 582, 1160, 58, C.ink, "s4-boundary-box");
  rect(ctx, slide, 58, 582, 7, 58, C.cyan, "s4-boundary-accent");
  text(ctx, slide, "答辩边界", 80, 592, 100, 20, {
    fontSize: 14,
    color: C.white,
    bold: true,
    name: "s4-boundary-title",
  });
  text(ctx, slide, "BMC 动态学习更自动；linux_accel 预装策略更精确、可分租户、可恢复。这里是工程取舍，不应伪装成同一机制。", 80, 616, 1106, 18, {
    fontSize: 11,
    color: "#B8C8D7",
    name: "s4-boundary-body",
  });
  footer(ctx, slide, 4, "BMC fixed commit 2997145508e0 · audited Linux 7.0/libbpf 1.6 compatibility patch");
  return slide;
}
