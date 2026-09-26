// ページの世界で動き、<video>/<audio> の音量にタブの音量（factor）を掛ける。
// ページ自身が設定した音量は覚えておき、ページから読むとその値が見えるようにする
// （YouTube などの音量つまみが Mixer の操作で動いてしまわないように）。
(() => {
  // 拡張の再読み込みなどで2回入れられても、二重に差し替えない
  // （このスクリプトは chrome.* を使わないので、古い版が残っていてもそのまま動き続ける）
  if (window.__mixerVolumeInstalled) return;
  window.__mixerVolumeInstalled = true;

  const native = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
  const pageVolume = new WeakMap(); // 要素 → ページが設定したつもりの音量
  const tracked = new Set();        // 音量を掛け直す対象（WeakRef）
  const seen = new WeakSet();
  let factor = 1;

  function track(element) {
    if (seen.has(element)) return;
    seen.add(element);
    tracked.add(new WeakRef(element));
    // 途中から入った場合は、ページがすでに設定していた音量を引き継ぐ
    if (!pageVolume.has(element)) pageVolume.set(element, native.get.call(element));
  }

  function apply(element) {
    native.set.call(element, Math.min(1, (pageVolume.get(element) ?? 1) * factor));
  }

  Object.defineProperty(HTMLMediaElement.prototype, "volume", {
    configurable: true,
    enumerable: native.enumerable,
    get() {
      return pageVolume.has(this) ? pageVolume.get(this) : native.get.call(this);
    },
    set(value) {
      native.set.call(this, value); // 範囲外の値ならここで本来どおり例外を出す
      track(this);
      pageVolume.set(this, value);
      apply(this);
    },
  });

  // 再生が始まった要素を拾う（DOM に無い new Audio() は play() の差し替えで拾う）
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    track(this);
    apply(this);
    return play.apply(this, args);
  };
  document.addEventListener("play", (event) => {
    if (event.target instanceof HTMLMediaElement) {
      track(event.target);
      apply(event.target);
    }
  }, true);

  // 音量は volume-bridge.js が <html data-mixer-volume="0.5"> に書いてから、このイベントで知らせてくる
  window.addEventListener("mixer:volume", () => {
    const value = Number(document.documentElement?.dataset.mixerVolume);
    if (!Number.isFinite(value)) return;
    factor = Math.max(0, Math.min(1, value));
    // スクリプトが入る前から再生中だった要素も拾う
    document.querySelectorAll("video, audio").forEach(track);
    for (const ref of tracked) {
      const element = ref.deref();
      if (element) apply(element);
      else tracked.delete(ref);
    }
  });
})();
