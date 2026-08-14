export const W = 1280;
export const H = 720;

export const C = {
  ink: "#071625",
  navy: "#0B2942",
  cyan: "#19C8E6",
  cyanSoft: "#DDF8FC",
  mint: "#4DE2BA",
  mintSoft: "#E3FBF4",
  amber: "#FFB84D",
  amberSoft: "#FFF2D8",
  coral: "#FF7262",
  coralSoft: "#FFE8E5",
  paper: "#F5F8FB",
  white: "#FFFFFF",
  line: "#CDD9E4",
  muted: "#607287",
  faint: "#E8EEF4",
  slate: "#2A4359",
};

export const FONT = "Hiragino Sans";
export const MONO = "Menlo";

export function rect(ctx, slide, x, y, width, height, fill, name, lineFill = fill, lineWidth = 0) {
  return ctx.addShape(slide, {
    x,
    y,
    width,
    height,
    fill,
    line: ctx.line(lineFill, lineWidth),
    name,
  });
}

export function text(ctx, slide, value, x, y, width, height, options = {}) {
  return ctx.addText(slide, {
    text: value,
    x,
    y,
    width,
    height,
    fontSize: options.fontSize ?? 24,
    color: options.color ?? C.ink,
    bold: options.bold ?? false,
    typeface: options.typeface ?? FONT,
    align: options.align ?? "left",
    valign: options.valign ?? "top",
    fill: options.fill ?? "#00000000",
    line: ctx.line(options.lineFill ?? "#00000000", options.lineWidth ?? 0),
    insets: options.insets ?? { left: 0, right: 0, top: 0, bottom: 0 },
    name: options.name,
  });
}

export function page(ctx, slide, number, kicker, title, subtitle = "") {
  rect(ctx, slide, 0, 0, W, H, C.paper, `s${number}-background`);
  rect(ctx, slide, 0, 0, 12, H, C.cyan, `s${number}-accent`);
  text(ctx, slide, kicker.toUpperCase(), 58, 35, 520, 24, {
    fontSize: 13,
    color: C.cyan,
    bold: true,
    name: `s${number}-kicker`,
  });
  text(ctx, slide, title, 58, 65, 1160, 62, {
    fontSize: 34,
    color: C.ink,
    bold: true,
    name: `s${number}-title`,
  });
  if (subtitle) {
    text(ctx, slide, subtitle, 60, 132, 1140, 26, {
      fontSize: 15,
      color: C.muted,
      name: `s${number}-subtitle`,
    });
  }
  text(ctx, slide, String(number).padStart(2, "0"), 1180, 674, 52, 22, {
    fontSize: 11,
    color: C.muted,
    typeface: MONO,
    align: "right",
    name: `s${number}-page`,
  });
}

export function footer(ctx, slide, number, source) {
  rect(ctx, slide, 58, 660, 1160, 1, C.line, `s${number}-footer-line`);
  text(ctx, slide, source, 60, 670, 1060, 20, {
    fontSize: 10,
    color: C.muted,
    typeface: MONO,
    name: `s${number}-footer-source`,
  });
}

export function pill(ctx, slide, value, x, y, width, options = {}) {
  const height = options.height ?? 34;
  return text(ctx, slide, value, x, y, width, height, {
    fontSize: options.fontSize ?? 14,
    color: options.color ?? C.ink,
    bold: options.bold ?? true,
    align: options.align ?? "center",
    valign: "middle",
    fill: options.fill ?? C.cyanSoft,
    lineFill: options.lineFill ?? options.fill ?? C.cyanSoft,
    lineWidth: options.lineWidth ?? 0,
    insets: { left: 8, right: 8, top: 2, bottom: 2 },
    name: options.name,
  });
}

export function metric(ctx, slide, value, label, x, y, width, options = {}) {
  text(ctx, slide, value, x, y, width, 54, {
    fontSize: options.valueSize ?? 40,
    color: options.color ?? C.cyan,
    bold: true,
    name: options.name ? `${options.name}-value` : undefined,
  });
  text(ctx, slide, label, x, y + 58, width, 36, {
    fontSize: options.labelSize ?? 14,
    color: options.labelColor ?? C.muted,
    name: options.name ? `${options.name}-label` : undefined,
  });
}

export function bar(ctx, slide, label, value, max, x, y, width, options = {}) {
  const labelWidth = options.labelWidth ?? 170;
  const barX = x + labelWidth;
  const barWidth = width - labelWidth - 88;
  text(ctx, slide, label, x, y - 2, labelWidth - 12, 26, {
    fontSize: options.fontSize ?? 14,
    color: options.labelColor ?? C.slate,
    bold: options.boldLabel ?? false,
    name: options.name ? `${options.name}-label` : undefined,
  });
  rect(ctx, slide, barX, y + 2, barWidth, 17, options.track ?? C.faint, options.name ? `${options.name}-track` : undefined);
  rect(
    ctx,
    slide,
    barX,
    y + 2,
    Math.max(2, (barWidth * value) / max),
    17,
    options.fill ?? C.cyan,
    options.name ? `${options.name}-fill` : undefined,
  );
  text(ctx, slide, options.display ?? String(value), barX + barWidth + 10, y - 4, 78, 28, {
    fontSize: options.fontSize ?? 14,
    color: options.valueColor ?? C.ink,
    bold: true,
    align: "right",
    name: options.name ? `${options.name}-value` : undefined,
  });
}

export function callout(ctx, slide, title, body, x, y, width, height, options = {}) {
  rect(ctx, slide, x, y, width, height, options.fill ?? C.white, options.name ? `${options.name}-box` : undefined, options.line ?? C.line, 1);
  rect(ctx, slide, x, y, 7, height, options.accent ?? C.cyan, options.name ? `${options.name}-accent` : undefined);
  text(ctx, slide, title, x + 20, y + 15, width - 36, 28, {
    fontSize: options.titleSize ?? 17,
    color: options.titleColor ?? C.ink,
    bold: true,
    name: options.name ? `${options.name}-title` : undefined,
  });
  text(ctx, slide, body, x + 20, y + 48, width - 36, height - 58, {
    fontSize: options.bodySize ?? 13,
    color: options.bodyColor ?? C.muted,
    name: options.name ? `${options.name}-body` : undefined,
  });
}
