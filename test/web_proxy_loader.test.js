// Runs the REAL proxy-loader block out of web_video_player_web.dart (between the
// BEGIN/END proxy-loader markers) in node, so the test cannot drift from what
// ships. Run: node --test test/web_proxy_loader.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const src = fs.readFileSync(
  path.join(__dirname, '..', 'lib', 'services', 'video', 'web_video_player_web.dart'),
  'utf8');
const m = /BEGIN proxy-loader[^\n]*\n([\s\S]*?)\n\s*\/\/ END proxy-loader/.exec(src);
assert.ok(m, 'proxy-loader markers not found in web_video_player_web.dart');
const block = m[1];

const PREFIX = 'https://api.allorigins.win/raw?url=';
const wrap = (u) => PREFIX + encodeURIComponent(u);

// Fresh player script scope per test; returns a loader that records the URL
// the default loader would have fetched.
function player(originalStreamUrl) {
  const fetched = [];
  class DefaultLoader {
    load(context) { fetched.push(context.url); }
  }
  const Hls = { DefaultConfig: { loader: DefaultLoader } };
  const factory = new Function('originalStreamUrl', 'Hls',
    block + '\nreturn { makeProxyLoader: makeProxyLoader };');
  const Loader = factory(originalStreamUrl, Hls).makeProxyLoader();
  const loader = new Loader();
  const load = (context) => { loader.load(context, {}, {}); return fetched[fetched.length - 1]; };
  return { load, fetched };
}

test('an already-proxied URL passes through untouched', () => {
  const p = player('http://host.example/live/master.m3u8');
  const u = wrap('http://host.example/live/master.m3u8');
  assert.strictEqual(p.load({ type: 'manifest', url: u }), u);
});

test('a relative segment hls.js mis-resolved against the proxy is re-wrapped under the real directory', () => {
  const p = player('http://host.example/live/master.m3u8');
  p.load({ type: 'manifest', url: wrap('http://host.example/live/master.m3u8') });
  // hls.js resolved "seg1.ts" against https://api.allorigins.win/raw?url=...
  const out = p.load({ url: 'https://api.allorigins.win/seg1.ts', frag: { level: 0 } });
  assert.strictEqual(out, wrap('http://host.example/live/seg1.ts'));
});

test('an absolute segment URL is proxied as is', () => {
  const p = player('http://host.example/live/master.m3u8');
  const out = p.load({ url: 'http://cdn.example/a/b.ts', frag: { level: 0 } });
  assert.strictEqual(out, wrap('http://cdn.example/a/b.ts'));
});

test('ABR level switch keeps one directory per level', () => {
  const p = player('http://host.example/live/master.m3u8');
  p.load({ type: 'manifest', url: wrap('http://host.example/live/master.m3u8') });
  p.load({ type: 'level', level: 0, url: wrap('http://host.example/live/low/index.m3u8') });
  p.load({ type: 'level', level: 1, url: wrap('http://host.example/live/high/index.m3u8') });
  assert.strictEqual(
    p.load({ url: 'https://api.allorigins.win/s1.ts', frag: { level: 0 } }),
    wrap('http://host.example/live/low/s1.ts'));
  assert.strictEqual(
    p.load({ url: 'https://api.allorigins.win/s9.ts', frag: { level: 1 } }),
    wrap('http://host.example/live/high/s9.ts'));
  // and back down again
  assert.strictEqual(
    p.load({ url: 'https://api.allorigins.win/s2.ts', frag: { level: 0 } }),
    wrap('http://host.example/live/low/s2.ts'));
});

for (const bad of ['', 'foo bar', '/relative/x.m3u8', 'http://']) {
  test('malformed stream URL ' + JSON.stringify(bad) + ' does not throw anywhere', () => {
    let p;
    assert.doesNotThrow(() => { p = player(bad); });
    // the proxied manifest request itself still goes out
    const manifestUrl = wrap(bad);
    assert.doesNotThrow(() => p.load({ type: 'manifest', url: manifestUrl }));
    assert.strictEqual(p.fetched[0], manifestUrl);
    // a relative URI with no known base is passed through unchanged
    assert.doesNotThrow(() => p.load({ type: 'level', level: 0, url: 'https://api.allorigins.win/x.m3u8' }));
    assert.strictEqual(p.fetched[1], 'https://api.allorigins.win/x.m3u8');
    assert.doesNotThrow(() => p.load({ url: 'https://api.allorigins.win/s.ts', frag: { level: 0 } }));
    assert.strictEqual(p.fetched[2], 'https://api.allorigins.win/s.ts');
    // an absolute segment still gets proxied
    assert.strictEqual(
      p.load({ url: 'http://cdn.example/a.ts', frag: { level: 0 } }),
      wrap('http://cdn.example/a.ts'));
  });
}

test('a lone surrogate in a URL does not throw', () => {
  const p = player('http://host.example/live/master.m3u8');
  assert.doesNotThrow(() => p.load({ url: 'http://cdn.example/\ud800.ts', frag: { level: 0 } }));
});

test('the script-level block runs without throwing for a malformed URL (no top-level URL parsing)', () => {
  const run = (u) => new Function('originalStreamUrl', 'Hls', block)(u, { DefaultConfig: { loader: class {} } });
  for (const bad of ['', 'foo bar', '/relative/x.m3u8', 'http://']) {
    assert.doesNotThrow(() => run(bad));
  }
});
