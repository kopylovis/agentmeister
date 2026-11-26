// Красная кнопка закрытия для снимка с листом: osascript -l JavaScript close_button.js <откуда.png> <куда.png>
// Пока у окна открыт лист, macOS рисует кнопку закрытия серой, и ее не включить. Скрипт находит красный круг
// в левом верхнем углу первого снимка, серый круг во втором и переносит пиксели первого во второй.
ObjC.import('AppKit');

function load(path) {
  var rep = $.NSBitmapImageRep.imageRepWithData($.NSData.dataWithContentsOfFile(path));
  rep.size = $.NSMakeSize(rep.pixelsWide, rep.pixelsHigh);
  return rep;
}

// центр и радиус первого (самого левого) круга, чьи пиксели подходят под test, в углу w x h
function circle(rep, test, w, h) {
  var pts = [];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var c = rep.colorAtXY(x, y);
      if (test(c.redComponent, c.greenComponent, c.blueComponent)) pts.push([x, y]);
    }
  }
  if (!pts.length) return null;
  var left = Math.min.apply(null, pts.map(function (p) { return p[0]; }));
  pts = pts.filter(function (p) { return p[0] < left + 24; });
  var xs = pts.map(function (p) { return p[0]; }), ys = pts.map(function (p) { return p[1]; });
  var x0 = Math.min.apply(null, xs), x1 = Math.max.apply(null, xs);
  var y0 = Math.min.apply(null, ys), y1 = Math.max.apply(null, ys);
  return {x: (x0 + x1 + 1) / 2, y: (y0 + y1 + 1) / 2, r: Math.max(x1 - x0 + 1, y1 - y0 + 1) / 2};
}

function run(argv) {
  var src = load(argv[0]), dst = load(argv[1]);
  var red = circle(src, function (r, g, b) { return r > 0.75 && g < 0.5 && b < 0.5; }, 260, 120);
  var gray = circle(dst, function (r, g, b) {
    return Math.abs(r - g) < 0.03 && Math.abs(g - b) < 0.03 && r > 0.3 && r < 0.6;
  }, 260, 120);
  if (!red || !gray) return 'no circles: red=' + JSON.stringify(red) + ' gray=' + JSON.stringify(gray);
  // меняются только пиксели круга, остальной снимок и его цветовой профиль (Display P3) не трогаются.
  // Край круга смешивается с фоном по расстоянию до центра, как сглаживание
  var r = gray.r + 0.5, dx = red.x - gray.x, dy = red.y - gray.y;
  for (var y = Math.floor(gray.y - r - 1); y <= gray.y + r + 1; y++) {
    for (var x = Math.floor(gray.x - r - 1); x <= gray.x + r + 1; x++) {
      var t = Math.max(0, Math.min(1, r - Math.hypot(x + 0.5 - gray.x, y + 0.5 - gray.y)));
      if (!t) continue;
      var a = dst.colorAtXY(x, y), b = src.colorAtXY(Math.round(x + dx), Math.round(y + dy));
      dst.setColorAtXY(a.blendedColorWithFractionOfColor(t, b), x, y);
    }
  }
  dst.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).writeToFileAtomically(argv[1], true);
  return 'red ' + JSON.stringify(red) + ' -> ' + JSON.stringify(gray);
}
