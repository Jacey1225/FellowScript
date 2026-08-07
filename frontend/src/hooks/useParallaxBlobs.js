import { useEffect, useRef } from 'react';

// Pointer-parallax "blob" background + floating dust motes, used behind the
// Home page's Hero and Community sections. Pass an array of container refs
// (each marking up its own [data-fs-blob]/[data-fs-dust] children); a single
// shared rAF loop + one window pointermove listener drives all of them.
// Skips entirely under prefers-reduced-motion.
export function useParallaxBlobs(refs) {
  const stateRef = useRef({ raf: null });

  useEffect(() => {
    if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    const roots = refs.map(r => r.current).filter(Boolean);
    const scenes = roots.map(buildScene);

    const onMove = (e) => {
      scenes.forEach((s) => {
        const r = s.root.getBoundingClientRect();
        s.tx = (e.clientX - (r.left + r.width / 2)) / Math.max(r.width, 1);
        s.ty = (e.clientY - (r.top + r.height / 2)) / Math.max(r.height, 1);
      });
    };
    const onLeave = () => scenes.forEach((s) => { s.tx = 0; s.ty = 0; });

    window.addEventListener('pointermove', onMove, { passive: true });
    window.addEventListener('pointerleave', onLeave);

    const t0 = performance.now();
    const tick = (now) => {
      const t = (now - t0) / 1000;
      scenes.forEach((s) => stepScene(s, t));
      stateRef.current.raf = requestAnimationFrame(tick);
    };
    stateRef.current.raf = requestAnimationFrame(tick);

    return () => {
      cancelAnimationFrame(stateRef.current.raf);
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerleave', onLeave);
      scenes.forEach(s => s.motes.forEach(m => m.el.remove()));
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}

function buildScene(root) {
  const blobs = Array.from(root.querySelectorAll('[data-fs-blob]')).map((el, i) => ({
    el,
    depth: parseFloat(el.getAttribute('data-fs-depth')) || 0.06,
    seed: i * 2.3,
  }));
  const host = root.querySelector('[data-fs-dust]');
  const motes = [];
  if (host) {
    const n = 46;
    for (let i = 0; i < n; i++) {
      const el = document.createElement('span');
      const size = 1 + Math.random() * 2.6;
      el.style.cssText = 'position:absolute;border-radius:50%;background:#FFF3E2;pointer-events:none;';
      el.style.width = size + 'px';
      el.style.height = size + 'px';
      el.style.opacity = String(0.18 + Math.random() * 0.5);
      el.style.filter = size > 2.4 ? 'blur(0.6px)' : 'none';
      host.appendChild(el);
      motes.push({
        el,
        bx: Math.random() * 100, by: Math.random() * 100,
        ax: 8 + Math.random() * 26, ay: 6 + Math.random() * 20,
        sx: 0.05 + Math.random() * 0.13, sy: 0.04 + Math.random() * 0.11,
        px: Math.random() * Math.PI * 2, py: Math.random() * Math.PI * 2,
        drift: 0.1 + Math.random() * 0.5,
      });
    }
  }
  return { root, blobs, motes, tx: 0, ty: 0, cx: 0, cy: 0 };
}

function stepScene(s, t) {
  s.cx += (s.tx - s.cx) * 0.045;
  s.cy += (s.ty - s.cy) * 0.045;
  s.blobs.forEach((b) => {
    const wob = 26 * b.depth * 10;
    const dx = s.cx * b.depth * 520 + Math.sin(t * 0.11 + b.seed) * wob;
    const dy = s.cy * b.depth * 380 + Math.cos(t * 0.09 + b.seed) * wob * 0.7;
    const scale = 1 + Math.sin(t * 0.13 + b.seed) * 0.02;
    b.el.style.transform = `translate3d(${dx.toFixed(2)}px,${dy.toFixed(2)}px,0) scale(${scale.toFixed(4)})`;
  });
  s.motes.forEach((m) => {
    const x = m.bx + Math.sin(t * m.sx + m.px) * (m.ax / 10) + s.cx * m.drift * 34;
    const y = m.by + Math.cos(t * m.sy + m.py) * (m.ay / 10) + s.cy * m.drift * 26;
    m.el.style.left = x.toFixed(3) + '%';
    m.el.style.top = y.toFixed(3) + '%';
  });
}
