// Rail's phone frames for a design page, and one phone alone when the address names it after #.
export const SCREENS = { ios: [417, 876], android: [432, 935] };

export function screenFromHash(hash) {
  const match = typeof hash === "string" ? /^#(ios|android)-([1-9]\d{0,2})$/.exec(hash) : null;
  return match ? { name: match[1], index: Number(match[2]) } : null;
}

// Tailwind's preflight makes every box border-box, and the bezel sits outside the device's screen. The rim keeps the
// phone's edge visible on a background as dark as the bezel, and stays visible when the tab shrinks the phone.
const FRAMES = `
[data-screen="ios"]{position:relative;box-sizing:content-box!important;width:393px;height:852px;border:12px solid #0b0b0f;border-radius:58px;overflow:hidden;outline:2px solid #4a4a52;outline-offset:-2px}
[data-screen="ios"]::before{content:"";position:absolute;top:11px;left:50%;translate:-50%;width:126px;height:37px;border-radius:999px;background:#000;z-index:2147483646}
[data-screen="ios"]::after{content:"";position:absolute;bottom:8px;left:50%;translate:-50%;width:134px;height:5px;border-radius:999px;background:#000;z-index:2147483646}
[data-screen="android"]{position:relative;box-sizing:content-box!important;width:412px;height:915px;border:10px solid #1b1b1f;border-radius:40px;overflow:hidden;outline:2px solid #4a4a52;outline-offset:-2px}
[data-screen="android"]::before{content:"";position:absolute;top:10px;left:50%;translate:-50%;width:18px;height:18px;border-radius:999px;background:#000;z-index:2147483646}
[data-screen="android"]::after{content:"";position:absolute;bottom:6px;left:50%;translate:-50%;width:108px;height:4px;border-radius:999px;background:#191c1b;z-index:2147483646}
`;

// Visibility inherits, so the shown phone is visible and whatever the mockup hid inside it stays hidden. A transformed
// ancestor would become the fixed phone's reference box, so its ancestors lose theirs.
const ALONE = `
html{overflow:hidden!important}
html,body{background:transparent!important}
body{visibility:hidden}
[data-rail-path]{transform:none!important;translate:none!important;scale:none!important;rotate:none!important;filter:none!important;perspective:none!important;contain:none!important;will-change:auto!important}
[data-rail-shown]{visibility:visible;position:fixed!important;top:0;left:0;margin:0!important;z-index:2147483645}
`;

function apply(doc, hash) {
  const wanted = screenFromHash(hash);
  const shown = wanted && doc.querySelectorAll(`[data-screen="${wanted.name}"]`)[wanted.index - 1];

  if (shown) {
    shown.setAttribute("data-rail-shown", "");
    for (let node = shown.parentElement; node && node !== doc.documentElement; node = node.parentElement)
      node.setAttribute("data-rail-path", "");
  }

  const style = doc.createElement("style");
  style.textContent = FRAMES + (shown ? ALONE : "");
  doc.head.append(style);
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", () => apply(document, location.hash));
  else apply(document, location.hash);
}
