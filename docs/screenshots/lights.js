// Кнопки окна на снимке демо: osascript -l JavaScript lights.js <снимок.png> [check | colors | fix [образец.png] | crop <выход.png>]
// check печатает, сколько из трех кнопок в левом верхнем углу серые. fix перекрашивает серые по образцу
// lights.png рядом со скриптом: под листом macOS всегда гасит кнопку закрытия, а неактивное окно гасит все три.
// Меняются только пиксели кругов, остальной снимок и его профиль Display P3 остаются как были.
// crop вырезает угол активного снимка в новый образец.
ObjC.import('AppKit');

var W = 320, H = 200;

function load(path) {
  var rep = $.NSBitmapImageRep.imageRepWithData($.NSData.dataWithContentsOfFile(path));
  rep.size = $.NSMakeSize(rep.pixelsWide, rep.pixelsHigh);
  return rep;
}

function kind(c) {
  var r = c.redComponent, g = c.greenComponent, b = c.blueComponent;
  var hi = Math.max(r, g, b), lo = Math.min(r, g, b);
  if (hi - lo < 0.04 && r > 0.3 && r < 0.62) return 'gray';
  if (hi > 0.6 && hi - lo > 0.35) return 'color';
  return null;
}

// три круга кнопок: связные пятна серого или яркого цвета размером с кнопку, верхние три в одну строку
function buttons(rep) {
  var marks = [];
  for (var y = 0; y < H; y++) for (var x = 0; x < W; x++) marks[y * W + x] = kind(rep.colorAtXY(x, y));
  var seen = [], spots = [];
  for (var i = 0; i < W * H; i++) {
    if (!marks[i] || seen[i]) continue;
    var stack = [i], pts = [], grays = 0;
    seen[i] = true;
    while (stack.length) {
      var j = stack.pop(), x = j % W, y = (j - x) / W;
      pts.push([x, y]);
      if (marks[j] === 'gray') grays++;
      [[1, 0], [-1, 0], [0, 1], [0, -1]].forEach(function (d) {
        var nx = x + d[0], ny = y + d[1], k = ny * W + nx;
        if (nx >= 0 && nx < W && ny >= 0 && ny < H && marks[k] && !seen[k]) { seen[k] = true; stack.push(k); }
      });
    }
    var xs = pts.map(function (p) { return p[0]; }), ys = pts.map(function (p) { return p[1]; });
    var w = Math.max.apply(null, xs) - Math.min.apply(null, xs) + 1, h = Math.max.apply(null, ys) - Math.min.apply(null, ys) + 1;
    if (w < 14 || w > 30 || Math.abs(w - h) > 4 || pts.length < 0.6 * Math.PI * w * h / 4) continue;
    spots.push({x: Math.min.apply(null, xs) + w / 2, y: Math.min.apply(null, ys) + h / 2, r: Math.max(w, h) / 2,
                gray: grays * 2 > pts.length});
  }
  spots.sort(function (a, b) { return a.y - b.y || a.x - b.x; });
  var row = spots.filter(function (s) { return spots.length && Math.abs(s.y - spots[0].y) <= 3; });
  return row.sort(function (a, b) { return a.x - b.x; }).slice(0, 3);
}

function save(rep, path) {
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).writeToFileAtomically(path, true);
}

function run(argv) {
  var path = argv[0], mode = argv[1] || 'check';
  var dst = load(path);
  if (mode === 'crop') {
    var part = $.CGImageCreateWithImageInRect(dst.CGImage, $.CGRectMake(0, 0, W, H));
    save($.NSBitmapImageRep.alloc.initWithCGImage(part), argv[2]);
    return JSON.stringify(buttons(load(argv[2])));
  }
  var found = buttons(dst);
  var gray = found.filter(function (b) { return b.gray; }).length;
  // colors: сколько кнопок цветные. Серые кнопки светлой темы почти сливаются с фоном и не находятся как серые,
  // поэтому активность окна надежнее проверять по цветным
  if (mode === 'colors') return String(found.filter(function (b) { return !b.gray; }).length);
  if (mode === 'check' || !gray) return String(gray);
  var here = $.NSString.stringWithString(path).stringByDeletingLastPathComponent.js;
  var ref = load(argv[2] || here + '/lights.png');
  var sample = buttons(ref);
  if (sample.length !== 3 || found.length !== 3) return 'buttons not found: ' + JSON.stringify(found);
  found.forEach(function (b, i) {
    if (!b.gray) return;
    var s = sample[i], r = b.r + 0.5, dx = s.x - b.x, dy = s.y - b.y;
    for (var y = Math.floor(b.y - r - 1); y <= b.y + r + 1; y++) {
      for (var x = Math.floor(b.x - r - 1); x <= b.x + r + 1; x++) {
        var t = Math.max(0, Math.min(1, r - Math.hypot(x + 0.5 - b.x, y + 0.5 - b.y)));
        if (!t) continue;
        dst.setColorAtXY(dst.colorAtXY(x, y).blendedColorWithFractionOfColor(t, ref.colorAtXY(Math.round(x + dx), Math.round(y + dy))), x, y);
      }
    }
  });
  save(dst, path);
  return 'fixed ' + gray;
}
