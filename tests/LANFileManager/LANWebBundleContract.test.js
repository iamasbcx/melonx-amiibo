// 使用 Node 内建 VM 模拟浏览器和服务器，不分配与游戏文件等大的测试缓冲。
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { webcrypto } = require("node:crypto");

const source = fs.readFileSync(path.resolve(__dirname, "../../src/MeloNX/MeloNX/Core/LANFileManager/LANWebBundle.swift"), "utf8");
const match = source.match(/static let javascript = #"""\r?\n([\s\S]*?)\r?\n    """#/);
assert.ok(match, "找不到内置网页 JavaScript");
const script = match[1].replace(
  /renderBreadcrumbs\(\);\s*renderResumeRecords\(\);\s*initialize\(\);/,
  "globalThis.web = { state, uploadOne, uploadFiles, fingerprint, renderEntries, download, discardResume, validRecord, downloadFolderItems, waitForDownload, prepareFolderDownload, newDownloadID, initialize };"
);
const MiB = 1024 * 1024;

class Element {
  constructor(tag = "div") { this.tag = tag; this.children = []; this.textContent = ""; this.innerHTML = ""; this.disabled = false; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  showModal() { this.open = true; }
  close() { this.open = false; }
  click() { if (this.onclick) return this.onclick(); }
  remove() {}
  setAttribute() {}
  removeAttribute() {}
}

function storage() {
  const map = new Map();
  return { getItem: key => map.get(key) || null, setItem: (key, value) => map.set(key, String(value)), removeItem: key => map.delete(key), map };
}

function fakeFile(size, marker = 7) {
  return {
    name: "large-game.nsp", size, lastModified: 123456789, webkitRelativePath: "",
    slice(start, end = size) {
      return { size: end - start, arrayBuffer: async () => {
        assert.ok(end - start <= 65536, "生产脚本不应把 500 MiB 分片读取成 ArrayBuffer");
        return new Uint8Array(end - start).fill(marker).buffer;
      } };
    }
  };
}

function backend() {
  const api = { sessions: new Map(), creates: 0, completes: 0, ranges: [], requests: [], xhrHeaders: [], failXHRAt: 0, failCompleteOnce: false };
  api.fetch = async (url, options = {}) => {
    const method = options.method || "GET";
    api.requests.push({ url, method, headers: options.headers || {} });
    assert.ok(!Object.keys(options.headers || {}).some(key => key.toLowerCase() === "authorization"), "网页请求不应携带访问鉴权头");
    assert.notEqual(url, "/api/v1/auth", "网页不应调用旧访问鉴权接口");
    if (url === "/api/v1/status") return response({ running: true });
    if (url.startsWith("/api/v1/files/list")) return response({ entries: [] });
    if (url.startsWith("/api/v1/transfers/downloads/")) return api.downloadStatus(url, options);
    if (url === "/api/v1/transfers/uploads" && method === "POST") {
      const input = JSON.parse(options.body);
      const id = "12345678-1234-1234-1234-" + String(++api.creates).padStart(12, "0");
      const snapshot = { uploadID: id, resumeToken: "resume-secret", destinationPath: input.path, totalBytes: input.size, nextOffset: 0, state: "uploading", clientFingerprint: input.clientFingerprint };
      api.sessions.set(id, snapshot);
      return response(snapshot);
    }
    const parsed = url.match(/\/transfers\/uploads\/([^/]+)(\/complete)?$/);
    if (!parsed) throw new Error("未知 Mock 请求：" + url);
    const snapshot = api.sessions.get(parsed[1]);
    if (!snapshot) return response({ error: "不存在" }, 404);
    if (options.headers["X-Resume-Token"] !== snapshot.resumeToken) return response({ error: "恢复凭据无效" }, 401);
    if (method === "DELETE") { api.sessions.delete(parsed[1]); return response({ cancelled: true }); }
    if (parsed[2]) {
      api.completes++;
      snapshot.state = "completed";
      if (api.failCompleteOnce) { api.failCompleteOnce = false; throw new TypeError("completion response lost"); }
    }
    return response(snapshot);
  };
  api.XHR = class {
    constructor() { this.upload = {}; this.headers = {}; }
    open(method, url) { assert.equal(method, "PUT"); this.url = url; }
    setRequestHeader(key, value) { assert.notEqual(key.toLowerCase(), "authorization", "分片请求不应携带访问鉴权头"); this.headers[key] = value; api.xhrHeaders.push([key, value]); }
    send(blob) {
      const range = this.headers["Content-Range"].match(/^bytes (\d+)-(\d+)\/(\d+)$/);
      const id = this.url.split("/").pop();
      const snapshot = api.sessions.get(id);
      assert.equal(this.headers["X-Resume-Token"], snapshot.resumeToken, "分片仍需绑定内部恢复凭据");
      const [start, end, total] = range.slice(1).map(Number);
      assert.equal(start, snapshot.nextOffset);
      assert.equal(total, snapshot.totalBytes);
      assert.equal(blob.size, end - start + 1);
      assert.ok(blob.size <= 500 * MiB);
      api.ranges.push([start, end, total]);
      queueMicrotask(() => {
        if (this.aborted) return;
        this.upload.onprogress?.({ lengthComputable: true, loaded: blob.size });
        snapshot.nextOffset = end + 1;
        if (api.failXHRAt === api.ranges.length) this.onerror();
        else { this.status = 200; this.responseText = JSON.stringify(snapshot); this.onload(); }
        this.onloadend?.();
      });
    }
    abort() { this.aborted = true; this.onabort?.(); this.onloadend?.(); }
  };
  return api;
}

function response(data, status = 200) { return { ok: status >= 200 && status < 300, status, statusText: String(status), json: async () => JSON.parse(JSON.stringify(data)) }; }

function browser(api, local = storage(), options = {}) {
  const elements = new Map();
  const nodes = [];
  const document = { body: new Element("body"), getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); }, createElement(tag) { const node = new Element(tag); if (tag === "a") node.click = () => api.onDownload?.(node.href); nodes.push(node); return node; } };
  // 不提供 sessionStorage，模拟直接打开 http://IP:端口；任何旧凭据访问都会导致测试失败。
  const context = { document, localStorage: local, location: { search: "", hash: "", pathname: "/" }, history: { replaceState() {} }, URLSearchParams, URL, Blob, Uint8Array, console, setTimeout, fetch: api.fetch, XMLHttpRequest: api.XHR, AbortController, crypto: options.crypto || webcrypto, Date: options.Date || Date };
  context.window = { confirm: () => true, prompt: () => null, setTimeout: options.setTimeout || setTimeout, clearTimeout: options.clearTimeout || clearTimeout, open() {} };
  vm.runInNewContext(script, context);
  return { web: context.web, elements, nodes, local };
}

test("1007 MiB 文件按 500+500+7 MiB 串行请求上传，完成后清除恢复记录", async () => {
  const api = backend(), page = browser(api);
  await page.web.uploadOne(fakeFile(1007 * MiB), "roms/large-game.nsp");
  assert.deepEqual(api.ranges.map(([start, end]) => end - start + 1), [500 * MiB, 500 * MiB, 7 * MiB]);
  assert.equal(api.creates, 1); assert.equal(api.completes, 1);
  assert.deepEqual(JSON.parse(page.local.getItem("melonx.lan.uploads.v1")), {});
  assert.equal([...page.web.state.transfers.values()][0].status, "已完成");
});

test("无 URL token 和 sessionStorage 时直接初始化并读取根目录", async () => {
  const api = backend(), page = browser(api);
  await page.web.initialize();
  assert.deepEqual(api.requests.map(request => request.url), ["/api/v1/status", "/api/v1/files/list?path="]);
  assert.ok(api.requests.every(request => !Object.keys(request.headers).some(key => key.toLowerCase() === "authorization")));
  assert.match(page.elements.get("service-state").textContent, /服务运行中/);
});

test("免访问鉴权后查询、分片和完成仍保留内部恢复凭据", async () => {
  const api = backend(), local = storage();
  api.failXHRAt = 1;
  await assert.rejects(browser(api, local).web.uploadOne(fakeFile(500 * MiB + 17), "roms/large-game.nsp"));
  api.failXHRAt = 0;
  await browser(api, local).web.uploadOne(fakeFile(500 * MiB + 17), "roms/large-game.nsp");
  const sessionRequests = api.requests.filter(request => /^\/api\/v1\/transfers\/uploads\//.test(request.url));
  assert.ok(sessionRequests.some(request => request.method === "GET"));
  assert.ok(sessionRequests.some(request => request.url.endsWith("/complete")));
  assert.ok(sessionRequests.every(request => request.headers["X-Resume-Token"] === "resume-secret"));
  assert.equal(api.xhrHeaders.filter(([key, value]) => key === "X-Resume-Token" && value === "resume-secret").length, 2);
});

test("服务连接失败提示检查前台服务并刷新，不展示鉴权流程", async () => {
  const api = backend(); api.fetch = async () => { throw new TypeError("offline"); };
  const page = browser(api);
  await page.web.initialize();
  assert.match(page.elements.get("service-state").textContent, /无法连接服务/);
  assert.match(page.elements.get("message-body").textContent, /刷新重试/);
});

// 虚拟计时器只推进轮询等待；请求超时回调由单独测试控制，避免测试真实等待数十秒。
function fastClock() {
  let now = 0;
  return {
    Date: class extends Date { static now() { return now; } },
    setTimeout(callback, delay) { const id = Symbol(); if (delay < 15000) queueMicrotask(() => { now += delay; callback(); }); return id; },
    clearTimeout() {},
  };
}

function downloadFiles() {
  return [{ path: "folder/a.nsp", size: 40 * 1024 * MiB, modifiedAt: 1 }, { path: "folder/b.nsp", size: 20 * 1024 * MiB, modifiedAt: 1 }];
}

test("目录队列等到上一项 sent 才启动下一项，重复点击不会重发已发送项", async () => {
  const api = backend(), events = [], ids = new Map(); let firstPoll = true;
  api.onDownload = href => { const url = new URL(href, "http://localhost"); const id = url.searchParams.get("downloadID"); const file = url.searchParams.get("path"); assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i); ids.set(id, file); events.push("start:" + file); };
  api.downloadStatus = async url => { const id = url.split("/").pop(), file = ids.get(id); const state = firstPoll ? "sending" : "sent"; firstPoll = false; events.push(state + ":" + file); return response({ state, path: file }); };
  const page = browser(api, storage(), { ...fastClock(), crypto: { getRandomValues: bytes => webcrypto.getRandomValues(bytes) } });
  page.web.state.folderDownloadEntries = downloadFiles();
  await page.web.downloadFolderItems();
  assert.deepEqual(events, ["start:folder/a.nsp", "sending:folder/a.nsp", "sent:folder/a.nsp", "start:folder/b.nsp", "sent:folder/b.nsp"]);
  await page.web.downloadFolderItems();
  assert.equal(events.length, 5);
  assert.match(page.elements.get("downloads-status").textContent, /服务端已发送 2 项/);
  assert.equal(page.elements.get("downloads-all").disabled, true);
});

test("服务端 failed、网络错误、未知状态、路径不匹配均暂停队列", async () => {
  for (const mode of ["failed", "network", "unknown", "wrongPath"]) {
    const api = backend(), starts = [];
    api.onDownload = href => starts.push(href);
    api.downloadStatus = async () => { if (mode === "network") throw new TypeError("offline"); return response({ state: mode === "unknown" ? "invalid" : mode === "wrongPath" ? "sent" : "failed", path: mode === "wrongPath" ? "other" : "folder/a.nsp" }); };
    const page = browser(api, storage(), fastClock()); page.web.state.folderDownloadEntries = downloadFiles();
    await page.web.downloadFolderItems();
    assert.equal(starts.length, 1, mode);
    assert.equal(page.web.state.folderDownloadCompleted.size, 0, mode);
    assert.equal(page.web.state.folderDownloadFailed.size, 1, mode);
    assert.match(page.elements.get("downloads-status").textContent, /已暂停/, mode);
  }
});

test("浏览器未发起下载时 waiting 超时，不继续第二项", async () => {
  const api = backend(), starts = [];
  api.onDownload = href => starts.push(href);
  api.downloadStatus = async () => response({ state: "waiting" });
  const page = browser(api, storage(), fastClock()); page.web.state.folderDownloadEntries = downloadFiles();
  await page.web.downloadFolderItems();
  assert.equal(starts.length, 1);
  assert.match(page.elements.get("downloads-status").textContent, /下载未开始/);
});

test("下载状态请求无响应时超时暂停，不启动第二项", async () => {
  const api = backend(), starts = [];
  api.onDownload = href => starts.push(href);
  api.downloadStatus = (url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener("abort", () => { const error = new Error("aborted"); error.name = "AbortError"; reject(error); });
  });
  const page = browser(api, storage(), { setTimeout(callback) { queueMicrotask(callback); return Symbol(); }, clearTimeout() {} });
  page.web.state.folderDownloadEntries = downloadFiles();
  await page.web.downloadFolderItems();
  assert.equal(starts.length, 1);
  assert.match(page.elements.get("downloads-status").textContent, /下载状态查询超时/);
});

test("活动下载期间防重入并阻止换目录；网络失败后继续查询旧 ID 不重发", async () => {
  const api = backend(), starts = []; let settle;
  api.onDownload = href => starts.push(href);
  api.downloadStatus = () => new Promise(resolve => { settle = resolve; });
  const page = browser(api, storage(), fastClock()); const files = downloadFiles(); page.web.state.folderDownloadEntries = files;
  const running = page.web.downloadFolderItems();
  await Promise.resolve();
  await page.web.downloadFolderItems();
  await page.web.prepareFolderDownload({ path: "another" });
  assert.equal(starts.length, 1); assert.equal(page.web.state.folderDownloadEntries, files);
  settle(response({ state: "failed", path: "folder/a.nsp" })); await running;
  api.downloadStatus = async url => response({ state: "sent", path: starts.length === 1 ? "folder/a.nsp" : "folder/b.nsp" });
  const retry = page.web.downloadFolderItems();
  page.elements.get("choice-actions").children[0].click();
  await retry;
  assert.equal(starts.length, 2);
  assert.equal(new URL(starts[1], "http://localhost").searchParams.get("path"), "folder/b.nsp");
});

test("分片已经落盘但响应丢失，网页重开后以服务器偏移续传", async () => {
  const api = backend(), local = storage(), first = browser(api, local);
  api.failXHRAt = 2;
  await assert.rejects(first.web.uploadOne(fakeFile(1007 * MiB), "roms/large-game.nsp"));
  assert.equal(Object.values(JSON.parse(local.getItem("melonx.lan.uploads.v1")))[0].nextOffset, 500 * MiB);
  api.failXHRAt = 0;
  await browser(api, local).web.uploadOne(fakeFile(1007 * MiB), "roms/large-game.nsp");
  assert.equal(api.creates, 1);
  assert.equal(api.ranges[2][0], 1000 * MiB);
  assert.equal(api.completes, 1);
});

test("完成响应丢失后恢复只接受 completed 收据，不重新上传或重复提交", async () => {
  const api = backend(), local = storage();
  api.failCompleteOnce = true;
  await assert.rejects(browser(api, local).web.uploadOne(fakeFile(17), "roms/large-game.nsp"));
  await browser(api, local).web.uploadOne(fakeFile(17), "roms/large-game.nsp");
  assert.equal(api.creates, 1); assert.equal(api.ranges.length, 1); assert.equal(api.completes, 1);
});

test("名称大小时间相同但头尾内容不同的文件产生不同恢复指纹", async () => {
  const page = browser(backend());
  assert.notEqual(await page.web.fingerprint(fakeFile(1024, 7), "a"), await page.web.fingerprint(fakeFile(1024, 8), "a"));
});

test("服务器拒绝恢复凭据时保留原记录，不静默创建新会话", async () => {
  const api = backend(), local = storage(), first = browser(api, local);
  api.failXHRAt = 1;
  await assert.rejects(first.web.uploadOne(fakeFile(17), "roms/large-game.nsp"));
  const records = JSON.parse(local.getItem("melonx.lan.uploads.v1"));
  Object.values(records)[0].resumeToken = "invalid"; local.setItem("melonx.lan.uploads.v1", JSON.stringify(records));
  await assert.rejects(browser(api, local).web.uploadOne(fakeFile(17), "roms/large-game.nsp"));
  assert.equal(api.creates, 1);
  assert.equal(Object.keys(JSON.parse(local.getItem("melonx.lan.uploads.v1"))).length, 1);
});

test("恶意文件名写入 textContent，下载链接不携带会话 token", () => {
  const page = browser(backend());
  page.web.state.entries = [{ name: '<img src=x onerror="alert(1)">', path: "roms/a #.nsp", kind: "file", size: 1, modifiedAt: 1 }];
  page.web.renderEntries();
  assert.ok(page.nodes.some(node => node.textContent === '<img src=x onerror="alert(1)">'));
  assert.ok(page.nodes.every(node => !node.innerHTML.includes("<img")));
  page.web.download("roms/a #.nsp");
  const link = page.nodes.at(-1);
  assert.equal(link.href, "/api/v1/files/download?path=roms%2Fa%20%23.nsp");
  assert.ok(!link.href.includes("token"));
});
