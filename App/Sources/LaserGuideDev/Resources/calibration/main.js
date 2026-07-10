// LaserGuide キャリブレーション UI (DR-0008 純 view: 幾何ロジック禁止)
//
// 役割:
//   1. Swift 側から push される RenderModel JSON を canvas + サイドバーへ描画する
//   2. マウス入力を CalibrationAction に変換して postMessage で Swift 側 store へ送る
//
// 禁則: エッジ検出 / スナップ / 座標変換 (論理↔物理) / 隣接判定 を JS で実装しない。
// これらは Swift 側の RenderModel が「有効な pose 適用済み physicalBounds」として持たせているので
// JS はそれをそのまま描くだけ (DR-0008 決定 1)。ドラッグ中の楽観描画は candidatePose を送信し、
// echo として戻ってくる RenderModel を再描画するだけで達成する (決定 3)。

'use strict';

// ============================================
// Bridge (Swift ↔ JS)
// ============================================

/**
 * Swift 側 (WKWebView + WKScriptMessageHandler "laserguide") への action 送信。
 * ブラウザ単体開発モード (webkit.messageHandlers が無い) では mock ブリッジに委譲する。
 */
function sendAction(action) {
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.laserguide;
  if (bridge) {
    bridge.postMessage(action);
  } else {
    mockBridge.dispatch(action);
  }
}

/** Swift 側から呼ばれる push エントリ。RenderModel JSON を受け取って再描画する。 */
window.__laserguideApplyRender = function(json) {
  try {
    const model = typeof json === 'string' ? JSON.parse(json) : json;
    applyRender(model);
  } catch (e) {
    console.error('applyRender error:', e);
    setStatus('Render error: ' + e.message, true);
  }
};

// ============================================
// Mock bridge (ブラウザ単体開発モード)
// ============================================

const mockBridge = (function () {
  // findings 2026-07-09-macos-display-api-verification.md §4 の実機トポロジ:
  // 内蔵 0..2056×0..1329 @2x / LG -258..3182×-1440..0 @1x
  // pose は @2x → 0.114924 mm/px 相当 (内蔵 344mm/1728px の 2 倍→3456px 換算に合わせず、ここでは
  // physicalBounds が視認できる程度のダミー値を使う。値の正しさより「描画・操作フローの疎通確認」)。
  function buildInitialState() {
    const displays = [
      { id: 'built-in', logicalBounds: rect(0, 0, 2056, 1329),
        pose: { translate: pt(0, 0), scaleX: 0.1, scaleY: 0.1 } },
      { id: 'LG', logicalBounds: rect(-258, -1440, 3182, 0),
        pose: { translate: pt(0, 0), scaleX: 0.3, scaleY: 0.3 } },
    ];
    return { displays, candidatePoses: {}, draggingDisplayId: null };
  }
  function rect(minX, minY, maxX, maxY) { return { minX, minY, maxX, maxY }; }
  function pt(x, y) { return { x, y }; }

  let state = buildInitialState();

  function effectivePose(d) {
    const c = state.candidatePoses[d.id];
    return c || d.pose;
  }
  function physicalBounds(d) {
    const p = effectivePose(d);
    const x0 = p.translate.x + d.logicalBounds.minX * p.scaleX;
    const x1 = p.translate.x + d.logicalBounds.maxX * p.scaleX;
    const y0 = p.translate.y + d.logicalBounds.minY * p.scaleY;
    const y1 = p.translate.y + d.logicalBounds.maxY * p.scaleY;
    return { minX: Math.min(x0, x1), minY: Math.min(y0, y1),
             maxX: Math.max(x0, x1), maxY: Math.max(y0, y1) };
  }
  function buildRenderModel() {
    return {
      yAxisDirection: 'down',
      draggingDisplayId: state.draggingDisplayId,
      hasPreview: Object.keys(state.candidatePoses).length > 0,
      displays: state.displays.map(d => ({
        id: d.id, name: d.id,
        logicalBounds: d.logicalBounds,
        physicalBounds: physicalBounds(d),
        poseTranslateMm: d.pose.translate,
        scaleXMmPerPx: d.pose.scaleX, scaleYMmPerPx: d.pose.scaleY,
        hasMillimeterInfo: true,
        candidatePoseTranslateMm: state.candidatePoses[d.id] ? state.candidatePoses[d.id].translate : null,
        isDragging: state.draggingDisplayId === d.id,
      })),
      // 表示のみ: 実機と等価な os / user 判定は Swift 側の責務。dev モードでは形だけの空配列。
      segments: [],
    };
  }
  function push() { window.__laserguideApplyRender(buildRenderModel()); }
  return {
    dispatch(action) {
      console.log('[mock] action:', action);
      switch (action.kind) {
        case 'calibration.dragStart': {
          state.draggingDisplayId = action.displayId;
          const d = state.displays.find(x => x.id === action.displayId);
          if (d && !state.candidatePoses[d.id]) {
            state.candidatePoses[d.id] = {
              translate: { x: d.pose.translate.x, y: d.pose.translate.y },
              scaleX: d.pose.scaleX, scaleY: d.pose.scaleY,
            };
          }
          break;
        }
        case 'calibration.dragMove': {
          if (state.draggingDisplayId !== action.displayId) break;
          state.candidatePoses[action.displayId] = action.candidatePose;
          break;
        }
        case 'calibration.dragEnd':
          state.draggingDisplayId = null;
          break;
        case 'calibration.commit': {
          for (const id in state.candidatePoses) {
            const d = state.displays.find(x => x.id === id);
            if (d) d.pose = state.candidatePoses[id];
          }
          state.candidatePoses = {};
          state.draggingDisplayId = null;
          break;
        }
        case 'calibration.cancel':
          state.candidatePoses = {};
          state.draggingDisplayId = null;
          break;
      }
      push();
    },
    boot() { push(); },
  };
})();

// ============================================
// Render state
// ============================================

let renderModel = null;
/** dragStart 時にスナップショットする「元の pose」。dragMove の候補 pose 構築に使う。 */
let dragOrigin = null;  // { displayId, translate: {x,y}, scaleX, scaleY }
let dragStartCanvas = null;  // {cx, cy}

// ============================================
// Canvas & 座標変換 (view 空間内のみ、幾何ロジックではない)
// ============================================

const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
let canvasScale = { scale: 1, offsetX: 0, offsetY: 0 };

function resizeCanvas() {
  const rect = canvas.parentElement.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.floor(rect.width * dpr));
  canvas.height = Math.max(1, Math.floor(rect.height * dpr));
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  draw();
}

/** 全モニタ physicalBounds を含む bbox を canvas に fit させる scale + offset を計算する。 */
function computeCanvasScale() {
  if (!renderModel || renderModel.displays.length === 0) return { scale: 1, offsetX: 0, offsetY: 0 };
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const d of renderModel.displays) {
    minX = Math.min(minX, d.physicalBounds.minX);
    minY = Math.min(minY, d.physicalBounds.minY);
    maxX = Math.max(maxX, d.physicalBounds.maxX);
    maxY = Math.max(maxY, d.physicalBounds.maxY);
  }
  const dpr = window.devicePixelRatio || 1;
  const padding = 40;
  const availW = canvas.width / dpr - padding * 2;
  const availH = canvas.height / dpr - padding * 2;
  const dataW = Math.max(1, maxX - minX);
  const dataH = Math.max(1, maxY - minY);
  const scale = Math.min(availW / dataW, availH / dataH);
  const offsetX = padding + (availW - dataW * scale) / 2 - minX * scale;
  // y-down (RenderModel.yAxisDirection = "down") なので canvas y と world y は同じ向き。反転しない。
  const offsetY = padding + (availH - dataH * scale) / 2 - minY * scale;
  return { scale, offsetX, offsetY };
}

function worldToCanvas(x, y) {
  const { scale, offsetX, offsetY } = canvasScale;
  return { x: x * scale + offsetX, y: y * scale + offsetY };
}
function canvasToWorld(cx, cy) {
  const { scale, offsetX, offsetY } = canvasScale;
  return { x: (cx - offsetX) / scale, y: (cy - offsetY) / scale };
}

// ============================================
// Drawing
// ============================================

function draw() {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.width / dpr, h = canvas.height / dpr;
  ctx.fillStyle = '#0f0f23';
  ctx.fillRect(0, 0, w, h);
  if (!renderModel) return;

  // Grid (mm 単位、視覚参照用のみ。幾何判定には使わない)
  drawGrid(w, h);

  // Displays (physicalBounds をそのまま描く。RenderModel が pose 適用済み)
  for (const d of renderModel.displays) {
    const p1 = worldToCanvas(d.physicalBounds.minX, d.physicalBounds.minY);
    const p2 = worldToCanvas(d.physicalBounds.maxX, d.physicalBounds.maxY);
    const x = Math.min(p1.x, p2.x), y = Math.min(p1.y, p2.y);
    const dw = Math.abs(p2.x - p1.x), dh = Math.abs(p2.y - p1.y);

    ctx.fillStyle = d.isDragging ? '#2a4a6a' : '#1a3a5a';
    ctx.fillRect(x, y, dw, dh);
    ctx.strokeStyle = d.isDragging ? '#4a9fff' : '#3a7fcf';
    ctx.lineWidth = d.isDragging ? 3 : 2;
    ctx.strokeRect(x, y, dw, dh);

    ctx.fillStyle = '#fff';
    ctx.font = 'bold 13px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(d.name, x + dw / 2, y + dh / 2);

    ctx.fillStyle = '#aaa';
    ctx.font = '10px sans-serif';
    ctx.fillText(
      `${Math.round(d.physicalBounds.maxX - d.physicalBounds.minX)}×${Math.round(d.physicalBounds.maxY - d.physicalBounds.minY)} mm`,
      x + dw / 2, y + dh / 2 + 16);
  }

  // Segments (表示のみ、edgeType で色分け。次ラウンドで編集 UI を足す)
  for (const s of renderModel.segments || []) {
    drawSegment(s);
  }
}

function drawGrid(w, h) {
  const { scale, offsetX, offsetY } = canvasScale;
  if (scale <= 0) return;
  const step = 100;  // 100mm ごとに薄いグリッド
  const wx0 = (0 - offsetX) / scale;
  const wx1 = (w - offsetX) / scale;
  const wy0 = (0 - offsetY) / scale;
  const wy1 = (h - offsetY) / scale;
  ctx.strokeStyle = 'rgba(255,255,255,0.04)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let x = Math.floor(wx0 / step) * step; x <= wx1; x += step) {
    const cx = x * scale + offsetX;
    ctx.moveTo(cx, 0); ctx.lineTo(cx, h);
  }
  for (let y = Math.floor(wy0 / step) * step; y <= wy1; y += step) {
    const cy = y * scale + offsetY;
    ctx.moveTo(0, cy); ctx.lineTo(w, cy);
  }
  ctx.stroke();
}

function drawSegment(s) {
  // 対応するモニタから physicalBounds を取ってセグメント辺を physical 空間に配置する。
  // 「pose 適用の bounding rect」の中で side を選ぶだけで、幾何計算ではない。
  const d = renderModel.displays.find(x => x.id === s.displayId);
  if (!d) return;
  const pb = d.physicalBounds;
  const lb = d.logicalBounds;
  // 論理 along-edge の [start,end] を bounding rect の対応辺上の比率で乗せる。
  // pose の scale が正である前提 (DisplayPose 契約) なので単調写像。
  const lenLogical = (s.side === 'top' || s.side === 'bottom')
    ? (lb.maxX - lb.minX) : (lb.maxY - lb.minY);
  const lenPhysical = (s.side === 'top' || s.side === 'bottom')
    ? (pb.maxX - pb.minX) : (pb.maxY - pb.minY);
  if (lenLogical <= 0 || lenPhysical <= 0) return;
  const alongScale = lenPhysical / lenLogical;
  let x1, y1, x2, y2;
  const alongMinLogical = (s.side === 'top' || s.side === 'bottom') ? lb.minX : lb.minY;
  const alongMinPhysical = (s.side === 'top' || s.side === 'bottom') ? pb.minX : pb.minY;
  const a1 = alongMinPhysical + (s.logicalStart - alongMinLogical) * alongScale;
  const a2 = alongMinPhysical + (s.logicalEnd   - alongMinLogical) * alongScale;
  switch (s.side) {
    case 'top':    x1 = a1; y1 = pb.minY; x2 = a2; y2 = pb.minY; break;
    case 'bottom': x1 = a1; y1 = pb.maxY; x2 = a2; y2 = pb.maxY; break;
    case 'left':   x1 = pb.minX; y1 = a1; x2 = pb.minX; y2 = a2; break;
    case 'right':  x1 = pb.maxX; y1 = a1; x2 = pb.maxX; y2 = a2; break;
    default: return;
  }
  const p1 = worldToCanvas(x1, y1);
  const p2 = worldToCanvas(x2, y2);
  ctx.strokeStyle = colorForEdgeType(s.edgeType, s.source);
  ctx.lineWidth = 3;
  if (s.source === 'os') { ctx.setLineDash([6, 4]); } else { ctx.setLineDash([]); }
  ctx.beginPath();
  ctx.moveTo(p1.x, p1.y); ctx.lineTo(p2.x, p2.y);
  ctx.stroke();
  ctx.setLineDash([]);
}

function colorForEdgeType(t, source) {
  // DR-0006 決定 1 の 4 値語彙。色は UI 目安のみ。
  switch (t) {
    case 'pp': return '#4a9fff';
    case 'pb': return '#e94560';
    case 'bp': return '#f0a020';
    case 'bb': return '#666';
    default:   return source === 'os' ? '#888' : '#e94560';
  }
}

// ============================================
// Hit test & drag
// ============================================

function findDisplayAt(cx, cy) {
  if (!renderModel) return null;
  const world = canvasToWorld(cx, cy);
  // 上に描いたものを優先する意図で逆順走査。現状は draw 順と同じだが将来の優先度リスト用。
  for (let i = renderModel.displays.length - 1; i >= 0; i--) {
    const d = renderModel.displays[i];
    const pb = d.physicalBounds;
    if (world.x >= pb.minX && world.x <= pb.maxX && world.y >= pb.minY && world.y <= pb.maxY) {
      return d;
    }
  }
  return null;
}

canvas.addEventListener('mousedown', (ev) => {
  const rect = canvas.getBoundingClientRect();
  const cx = ev.clientX - rect.left, cy = ev.clientY - rect.top;
  const d = findDisplayAt(cx, cy);
  if (!d) return;
  dragOrigin = {
    displayId: d.id,
    translate: { x: d.poseTranslateMm.x, y: d.poseTranslateMm.y },
    scaleX: d.scaleXMmPerPx, scaleY: d.scaleYMmPerPx,
  };
  dragStartCanvas = { cx, cy };
  canvas.classList.add('dragging');
  sendAction({ kind: 'calibration.dragStart', displayId: d.id });
});

canvas.addEventListener('mousemove', (ev) => {
  if (!dragOrigin) return;
  const rect = canvas.getBoundingClientRect();
  const cx = ev.clientX - rect.left, cy = ev.clientY - rect.top;
  const { scale } = canvasScale;
  if (scale <= 0) return;
  // 物理 mm 空間での delta (canvas 空間の px を scale で割るだけ、幾何計算ではない座標系変換)
  const dxMm = (cx - dragStartCanvas.cx) / scale;
  const dyMm = (cy - dragStartCanvas.cy) / scale;
  const candidatePose = {
    translate: { x: dragOrigin.translate.x + dxMm, y: dragOrigin.translate.y + dyMm },
    scaleX: dragOrigin.scaleX, scaleY: dragOrigin.scaleY,
  };
  sendAction({ kind: 'calibration.dragMove', displayId: dragOrigin.displayId, candidatePose });
});

function endDrag() {
  if (!dragOrigin) return;
  sendAction({ kind: 'calibration.dragEnd' });
  dragOrigin = null;
  dragStartCanvas = null;
  canvas.classList.remove('dragging');
}
canvas.addEventListener('mouseup', endDrag);
canvas.addEventListener('mouseleave', endDrag);

document.getElementById('btn-commit').addEventListener('click', () => {
  sendAction({ kind: 'calibration.commit' });
  setStatus('確定を送信');
});
document.getElementById('btn-cancel').addEventListener('click', () => {
  sendAction({ kind: 'calibration.cancel' });
  setStatus('取り消しを送信');
});
document.getElementById('btn-export').addEventListener('click', () => {
  const el = document.getElementById('json-out');
  el.value = renderModel ? JSON.stringify(renderModel, null, 2) : '';
  setStatus('現在の RenderModel を Export');
});

// ============================================
// Apply / UI update
// ============================================

function applyRender(model) {
  renderModel = model;
  canvasScale = computeCanvasScale();
  draw();
  updateMonitorList();
  updateSegmentList();
  setStatus(model.hasPreview ? 'プレビュー中 (未確定)' : 'アイドル');
}

function updateMonitorList() {
  const list = document.getElementById('monitor-list');
  if (!renderModel || renderModel.displays.length === 0) {
    list.textContent = 'モニタなし';
    return;
  }
  list.innerHTML = '';
  for (const d of renderModel.displays) {
    const item = document.createElement('div');
    item.className = 'monitor-item' + (d.isDragging ? ' dragging' : '');
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = d.name;
    const info = document.createElement('div');
    info.className = 'info';
    const cand = d.candidatePoseTranslateMm;
    info.textContent = [
      `論理: ${Math.round(d.logicalBounds.maxX - d.logicalBounds.minX)}×${Math.round(d.logicalBounds.maxY - d.logicalBounds.minY)} px`,
      `pose translate: (${d.poseTranslateMm.x.toFixed(1)}, ${d.poseTranslateMm.y.toFixed(1)}) mm`,
      cand ? `候補 translate: (${cand.x.toFixed(1)}, ${cand.y.toFixed(1)}) mm` : null,
      `mm/px: (${d.scaleXMmPerPx.toFixed(3)}, ${d.scaleYMmPerPx.toFixed(3)})`,
      d.hasMillimeterInfo ? null : 'mm 情報なし',
    ].filter(Boolean).join('\n');
    info.style.whiteSpace = 'pre-line';
    item.appendChild(name);
    item.appendChild(info);
    list.appendChild(item);
  }
}

function updateSegmentList() {
  const list = document.getElementById('segment-list');
  if (!renderModel || !renderModel.segments || renderModel.segments.length === 0) {
    list.textContent = 'セグメントなし';
    return;
  }
  list.innerHTML = '';
  for (const s of renderModel.segments) {
    const row = document.createElement('div');
    const badge = document.createElement('span');
    badge.className = 'badge ' + s.edgeType;
    badge.textContent = s.edgeType.toUpperCase();
    row.appendChild(badge);
    const text = document.createElement('span');
    text.textContent = `[${s.source}] ${s.displayId}.${s.side} [${Math.round(s.logicalStart)}..${Math.round(s.logicalEnd)}]`;
    row.appendChild(text);
    list.appendChild(row);
  }
}

function setStatus(msg, isError) {
  const el = document.getElementById('status');
  el.textContent = msg;
  el.style.color = isError ? '#e94560' : '#8ac';
}

// ============================================
// Boot
// ============================================

window.addEventListener('resize', () => { canvasScale = computeCanvasScale(); resizeCanvas(); });
requestAnimationFrame(() => {
  resizeCanvas();
  // Swift 側 bridge があれば、Swift 側の viewDidLoad 相当のタイミングで
  // __laserguideApplyRender が最初に呼ばれる。無ければ (ブラウザ dev) mock を起動する。
  const hasBridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.laserguide;
  if (!hasBridge) {
    setStatus('ブラウザ dev モード (mock bridge)');
    mockBridge.boot();
  } else {
    // Swift 側からの初回 push を待つ間の暫定表示
    setStatus('Swift ブリッジ待機中');
    sendAction({ kind: 'calibration.requestInitialRender' });
  }
});
