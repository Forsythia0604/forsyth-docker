"use strict";

// This file is independent of both signed apps. Editing layout rules does not change permissions.
var DockLayout = (() => {
  const version = "1.1.0";
  const gap = 8;
  const tolerance = 14;
  const right = r => r.x + r.width;
  const top = r => r.y + r.height;
  const close = (a, b, t = tolerance) => Math.abs(a - b) <= t;
  const same = (a, b) => ["x", "y", "width", "height"].every(k => close(a[k], b[k], 1));
  const finite = r => r && ["x", "y", "width", "height"].every(k => Number.isFinite(r[k])) && r.width > 0 && r.height > 0;
  const anchor = (value, origin, length, fractions) => {
    let nearest = null;
    for (const f of fractions) {
      const delta = value - origin - length * f;
      if (Math.abs(delta) <= tolerance && (!nearest || Math.abs(delta) < Math.abs(nearest.delta))) nearest = {f, delta};
    }
    return nearest;
  };
  const safeArea = geometry => {
    const a = geometry.available;
    const bottom = Math.max(a.y, Math.ceil(top(geometry.dock) + gap));
    return {x: a.x, y: bottom, width: a.width, height: top(a) - bottom};
  };
  const verticalSlot = (r, area) => {
    const low = anchor(r.y, area.y, area.height, [0, .5, 1]);
    const high = anchor(top(r), area.y, area.height, [0, .5, 1]);
    if (!low || !high || high.f <= low.f) return null;
    return {low, high};
  };
  const horizontalSlot = (r, area) => {
    const fractions = [0, .25, 1/3, .5, 2/3, .75, 1];
    const low = anchor(r.x, area.x, area.width, fractions);
    const high = anchor(right(r), area.x, area.width, fractions);
    return low && high && high.f > low.f;
  };
  function classify(window, geometry) {
    if (!finite(window) || !geometry || !finite(geometry.screen) || !finite(geometry.available) || !finite(geometry.dock)) return null;
    const screen = geometry.screen, area = geometry.available, safe = safeArea(geometry);
    const cx = window.x + window.width / 2, cy = window.y + window.height / 2;
    if (cx < screen.x || cx >= right(screen) || cy < screen.y || cy >= top(screen) || safe.height < 80) return null;
    const horizontal = horizontalSlot(window, area);
    const native = verticalSlot(window, area);
    if (native && (horizontal || native.high.f - native.low.f === 1)) return {source: window, kind: "native"};
    const fitted = verticalSlot(window, safe);
    if (fitted && (horizontal || fitted.high.f - fitted.low.f === 1)) {
      const bottom = area.y + area.height * fitted.low.f + fitted.low.delta;
      const upper = area.y + area.height * fitted.high.f + fitted.high.delta;
      return {source: {x: window.x, y: bottom, width: window.width, height: upper - bottom}, kind: "fitted"};
    }
    return null;
  }
  function adjust(window, geometry) {
    const intent = classify(window, geometry);
    if (!intent) return null;
    const area = geometry.available, safe = safeArea(geometry), source = intent.source;
    const slot = verticalSlot(source, area);
    if (!slot) return null;
    const bottom = Math.max(safe.y, safe.y + safe.height * slot.low.f + slot.low.delta);
    const upper = Math.min(top(safe), safe.y + safe.height * slot.high.f + slot.high.delta);
    const target = {x: window.x, y: Math.round(bottom), width: window.width, height: Math.floor(upper - Math.round(bottom))};
    if (!finite(target) || target.height < 80 || same(window, target)) return null;
    return {rect: target, kind: "native"};
  }
  return {version, gap, safeArea, classify, adjust};
})();

if (typeof module !== "undefined") module.exports = DockLayout;
