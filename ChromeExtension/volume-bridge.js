// 拡張の世界（background.js）とページの世界（volume-main.js）の橋渡し。
// ページの JavaScript には chrome.runtime が無いため、DOM を通して音量を渡す。
// CustomEvent の detail は拡張の世界からページの世界へ渡らない（届くと null になる）ので、
// 両方の世界から見える <html> の属性に音量を書き、合図のイベントだけを送る。
// （拡張を入れた直後は background.js からも入れられるが、二重に届いても同じ音量を掛け直すだけで害はない）
function applyVolume(volume) {
  if (typeof volume !== "number" || !document.documentElement) return;
  document.documentElement.dataset.mixerVolume = String(volume);
  window.dispatchEvent(new Event("mixer:volume"));
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === "volume") applyVolume(message.volume);
});

// 読み込み時点で音量が下げてあるタブなら、最初から反映する
chrome.runtime.sendMessage({ type: "getVolume" }).then(applyVolume).catch(() => {});
