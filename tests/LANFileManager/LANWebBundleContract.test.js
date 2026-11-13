// 使用 Node 内建 VM 模拟浏览器和服务器，不分配与游戏文件等大的测试缓冲。
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../src/MeloNX/MeloNX/Core/LANFileManager/LANWebBundle.swift"), "utf8");
const match = source.match(/static let javascript = #"""\r?\n([\s\S]*?)\r?\n    """#/);
assert.ok(match, "找不到内置网页 JavaScript");
const script = match[1].replace(
  /renderBreadcrumbs\(\);\s*renderResumeRecords\(\);\s*initialize\(\);/,
  "globalThis.web = { state, uploadOne, uploadFiles, fingerprint, renderEntries, download, discardResume, validRecord };"
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
  const api = { sessions: new Map(), creates: 0, completes: 0, ranges: [], failXHRAt: 0, failCompleteOnce: false };
  api.fetch = async (url, options = {}) => {
    const method = options.method || "GET";
    if (url === "/api/v1/status") return response({ running: true });
    if (url.startsWith("/api/v1/files/list")) return response({ entries: [] });
    if (url === "/api/v1/auth") return response({ authenticated: true });
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
    setRequestHeader(key, value) { this.headers[key] = value; }
    send(blob) {
      const range = this.headers["Content-Range"].match(/^bytes (\d+)-(\d+)\/(\d+)$/);
      const id = this.url.split("/").pop();
      const snapshot = api.sessions.get(id);
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

function browser(api, local = storage()) {
  const elements = new Map();
  const nodes = [];
  const document = { body: new Element("body"), getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); }, createElement(tag) { const node = new Element(tag); nodes.push(node); return node; } };
  const context = { document, localStorage: local, sessionStorage: storage(), location: { search: "", hash: "#token=service-secret", pathname: "/" }, history: { replaceState() {} }, URLSearchParams, URL, Blob, Uint8Array, console, setTimeout, fetch: api.fetch, XMLHttpRequest: api.XHR };
  context.window = { confirm: () => true, prompt: () => null, setTimeout, open() {} };
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
