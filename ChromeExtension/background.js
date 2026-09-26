// Mixer.app と WebSocket でつながり、音の出ているタブの一覧を送り、Mixer からの操作を受け取る。
// Mixer 側のポート番号は ChromeTabBridge.swift と合わせること。
const MIXER_URL = "ws://127.0.0.1:47219";

let socket = null;

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  socket = new WebSocket(MIXER_URL);
  socket.onopen = () => sendTabs();
  socket.onmessage = (event) => handleCommand(JSON.parse(event.data));
  socket.onclose = () => { socket = null; };
  socket.onerror = () => {}; // Mixer が起動していないだけなら onclose → 再接続を待つ
}

// Service Worker は放っておくと止まるので、
// 接続中は 20 秒ごとに通信して起こしておき、未接続なら alarms で定期的に再接続を試みる
setInterval(() => {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: "ping" }));
  } else {
    connect();
  }
}, 20_000);
chrome.alarms.create("reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(connect);
connect();

// MARK: - タブ一覧の送信

// タブごとの音量（0〜1）。Service Worker が止まっても消えないよう session storage に置く
async function getVolumes() {
  return (await chrome.storage.session.get("volumes")).volumes ?? {};
}

async function sendTabs() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  const volumes = await getVolumes();
  const tabs = await chrome.tabs.query({});
  const list = tabs
    // 音が出ているタブに加えて、ミュート中・音量を下げたタブも（音が止まっていても）載せる
    .filter((tab) => tab.audible || tab.mutedInfo?.muted || (volumes[tab.id] ?? 1) < 1)
    .map((tab) => ({
      id: tab.id,
      title: tab.title || tab.url || "",
      muted: !!tab.mutedInfo?.muted,
      volume: volumes[tab.id] ?? 1,
    }));
  socket.send(JSON.stringify({ type: "tabs", tabs: list }));
}

chrome.tabs.onUpdated.addListener((_tabId, change) => {
  if ("audible" in change || "mutedInfo" in change || "title" in change) sendTabs();
});
chrome.tabs.onRemoved.addListener(async (tabId) => {
  const volumes = await getVolumes();
  delete volumes[tabId];
  await chrome.storage.session.set({ volumes });
  sendTabs();
});

// MARK: - Mixer からの操作

async function handleCommand(command) {
  switch (command.type) {
    case "setMuted":
      // 変更は onUpdated（mutedInfo）経由で Mixer に送り返される
      await chrome.tabs.update(command.tabId, { muted: command.muted });
      break;
    case "setVolume": {
      const volumes = await getVolumes();
      volumes[command.tabId] = command.volume;
      await chrome.storage.session.set({ volumes });
      // タブ内の全フレームの volume-bridge.js に届く。ページ読み込み前などで届かなくても問題ない
      chrome.tabs.sendMessage(command.tabId, { type: "volume", volume: command.volume }).catch(() => {});
      sendTabs();
      break;
    }
  }
}

// 拡張を入れた・更新した時点ですでに開いていたタブには content_scripts が入らないので、
// 再読み込みしなくても音量を変えられるよう、ここで入れる
chrome.runtime.onInstalled.addListener(async () => {
  for (const tab of await chrome.tabs.query({})) {
    const target = { tabId: tab.id, allFrames: true };
    // chrome:// のページなど、入れられないタブは飛ばす
    chrome.scripting.executeScript({ target, files: ["volume-main.js"], world: "MAIN" }).catch(() => {});
    chrome.scripting.executeScript({ target, files: ["volume-bridge.js"] }).catch(() => {});
  }
});

// ページ読み込み時に、そのタブの音量を volume-bridge.js に教える
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type !== "getVolume" || sender.tab?.id === undefined) return;
  getVolumes().then((volumes) => sendResponse(volumes[sender.tab.id] ?? 1));
  return true; // sendResponse を非同期で呼ぶ
});
