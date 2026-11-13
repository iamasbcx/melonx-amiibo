import Foundation

/// 局域网文件管理网页的内置资源。
///
/// 网页只依赖标准浏览器 API，不把第三方脚本引入 App Bundle。所有用户文件名
/// 都通过 `textContent` 写入 DOM；上传使用有序分片，恢复记录只放在浏览器本地。
nonisolated enum LANWebBundle {
    static let html = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <title>MeloNX 局域网文件管理</title>
      <link rel="stylesheet" href="/app.css">
    </head>
    <body>
      <main class="shell">
        <header class="topbar">
          <div>
            <h1>MeloNX 文件管理</h1>
            <p id="service-state" class="muted">正在读取服务状态…</p>
          </div>
          <div class="top-actions">
            <button id="refresh" type="button">刷新</button>
            <button id="help" type="button" class="secondary">说明</button>
          </div>
        </header>

        <section class="toolbar" aria-label="文件操作">
          <div id="breadcrumbs" class="breadcrumbs"></div>
          <div class="toolbar-actions">
            <button id="mkdir" type="button">新建文件夹</button>
            <label class="button">
              上传文件
              <input id="file-input" type="file" multiple hidden>
            </label>
            <label class="button">
              上传文件夹
              <input id="folder-input" type="file" webkitdirectory multiple hidden>
            </label>
            <button id="resume-tools" type="button" class="secondary">恢复记录</button>
          </div>
        </section>

        <section id="transfer-panel" class="transfer-panel" hidden>
          <div class="transfer-title"><strong>传输任务</strong><span id="transfer-hint" class="muted"></span><button id="pause-uploads" class="secondary" type="button" hidden>暂停上传</button></div>
          <div id="transfer-list" class="transfer-list"></div>
        </section>
        <section id="resume-panel" class="transfer-panel" hidden><strong>未完成上传</strong><p class="muted">重新选择原文件继续。地址或端口变化前可导出恢复记录，再在新网页导入；记录包含恢复凭据，请妥善保管。</p><div id="resume-list"></div></section>

        <section class="table-wrap">
          <table>
            <thead><tr><th>名称</th><th>类型</th><th>大小</th><th>修改时间</th><th>操作</th></tr></thead>
            <tbody id="file-list"><tr><td colspan="5" class="empty">正在读取…</td></tr></tbody>
          </table>
        </section>
        <p class="footnote">上传或下载大型游戏时请保持 MeloNX 在前台并避免锁屏。未完成上传会保留为临时分片，可在网页重新打开后继续。</p>
      </main>
      <dialog id="message-dialog"><form method="dialog"><h2 id="message-title">提示</h2><p id="message-body"></p><button>确定</button></form></dialog>
      <dialog id="choice-dialog"><h2 id="choice-title"></h2><p id="choice-body"></p><div id="choice-actions" class="top-actions"></div></dialog>
      <dialog id="downloads-dialog"><h2>文件夹下载清单</h2><p class="muted">逐个下载原文件，无需 ZIP。请在保存时保留所示相对路径。浏览器可能询问是否允许多个下载。</p><div id="downloads-list"></div><p><button id="downloads-all">下载全部</button> <button id="downloads-close" class="secondary">关闭</button></p></dialog>
      <input id="resume-import" type="file" accept="application/json,.json" hidden>
      <script src="/app.js" defer></script>
    </body>
    </html>
    """#

    static let css = #"""
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #f4f6f8; color: #17212b; }
    .shell { max-width: 1180px; margin: 0 auto; padding: 24px; }
    .topbar, .toolbar, .transfer-panel { background: Canvas; border: 1px solid #d9e0e7; border-radius: 14px; padding: 18px; margin-bottom: 14px; }
    .topbar { display: flex; justify-content: space-between; gap: 16px; align-items: center; }
    h1 { margin: 0 0 4px; font-size: 1.35rem; }
    h2 { margin-top: 0; }
    button, .button { appearance: none; border: 0; border-radius: 9px; padding: 9px 13px; background: #0a66c2; color: white; font-size: .92rem; cursor: pointer; display: inline-flex; align-items: center; gap: 6px; }
    button:hover, .button:hover { filter: brightness(1.1); }
    button:disabled { opacity: .5; cursor: default; }
    button.secondary, .secondary { background: #e8edf2; color: #17212b; }
    button.danger { background: #c62828; }
    .top-actions, .toolbar-actions { display: flex; gap: 8px; flex-wrap: wrap; }
    .toolbar { display: flex; justify-content: space-between; gap: 12px; align-items: center; }
    .breadcrumbs { display: flex; gap: 5px; flex-wrap: wrap; align-items: center; min-height: 32px; }
    .crumb { background: transparent; color: #0a66c2; padding: 5px 3px; }
    .crumb.current { color: inherit; font-weight: 600; }
    .table-wrap { overflow-x: auto; background: Canvas; border: 1px solid #d9e0e7; border-radius: 14px; }
    table { border-collapse: collapse; min-width: 760px; width: 100%; }
    th, td { border-bottom: 1px solid #e2e7ec; text-align: left; padding: 11px 13px; vertical-align: middle; }
    th { font-size: .83rem; color: #607080; font-weight: 600; }
    td.name { min-width: 240px; word-break: break-all; }
    .name-button { background: transparent; color: #0a66c2; padding: 0; }
    .row-actions { display: flex; gap: 5px; flex-wrap: wrap; }
    .row-actions button { font-size: .82rem; padding: 6px 8px; }
    .muted, .footnote { color: #657483; font-size: .88rem; }
    .footnote { margin: 14px 3px; }
    .empty { text-align: center; color: #657483; padding: 30px; }
    .transfer-title { display: flex; justify-content: space-between; gap: 12px; margin-bottom: 9px; }
    .transfer-item { display: grid; grid-template-columns: minmax(120px, 1fr) minmax(120px, 1fr) minmax(160px, 2fr) 80px; align-items: center; gap: 9px; padding: 8px 0; border-top: 1px solid #e2e7ec; overflow-wrap: anywhere; }
    .resume-item { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 9px 0; border-bottom: 1px solid #d9e0e7; overflow-wrap: anywhere; }
    #downloads-list { max-height: 50vh; overflow-y: auto; }
    #downloads-list a { display: block; margin: 8px 0; overflow-wrap: anywhere; }
    progress { width: 100%; height: 9px; }
    dialog { border: 0; border-radius: 12px; padding: 22px; max-width: 440px; box-shadow: 0 12px 50px #0006; }
    dialog::backdrop { background: #0007; }
    @media (prefers-color-scheme: dark) { body { background: #101418; color: #edf2f6; } .topbar, .toolbar, .transfer-panel, .table-wrap { border-color: #2a343e; } button.secondary, .secondary { background: #2a343e; color: #edf2f6; } th, td, .transfer-item { border-color: #2a343e; } }
    @media (max-width: 720px) { .shell { padding: 10px; } .topbar, .toolbar { align-items: flex-start; flex-direction: column; } .transfer-item { grid-template-columns: 1fr 90px; } .transfer-item progress { grid-column: 1 / -1; } }
    """#

    static let javascript = #"""
    (() => {
        "use strict";
        // 每个 HTTP 请求固定 500 MiB；请求串行发送，断线只重传当前分片。
        const CHUNK_SIZE = 500 * 1024 * 1024;
        const RESUME_KEY = "melonx.lan.uploads.v1";
        const tokenFromURL = () => {
            const params = new URLSearchParams(location.search);
            const value =
                params.get("token") ||
                (location.hash.startsWith("#token=") ? location.hash.slice(7) : "");
            if (value) {
                sessionStorage.setItem("melonx.lan.token", value);
                history.replaceState(null, "", location.pathname);
            }
            return value || sessionStorage.getItem("melonx.lan.token") || "";
        };
        const token = tokenFromURL();
        const state = {
            path: "",
            entries: [],
            transfers: new Map(),
            busy: false,
            pauseRequested: false,
            folderDownloadEntries: [],
            activeXHR: null,
            directoryRequest: 0,
        };
        const $ = (id) => document.getElementById(id);
        const openDialog = (dialog) =>
            typeof dialog.showModal === "function"
                ? dialog.showModal()
                : dialog.setAttribute("open", "");
        const closeDialog = (dialog) =>
            typeof dialog.close === "function"
                ? dialog.close()
                : dialog.removeAttribute("open");
        const apiURL = (path) => path;
        const headers = (extra = {}) =>
            Object.assign({ Authorization: `Bearer ${token}` }, extra);
        const json = async (url, options = {}) => {
            const response = await fetch(
                apiURL(url),
                Object.assign({}, options, {
                    headers: headers(options.headers || {}),
                }),
            );
            let data = null;
            try {
                data = await response.json();
            } catch (_) {
                /* 错误响应可能没有 JSON 正文 */
            }
            if (!response.ok) {
                const message =
                    data?.error?.message ||
                    data?.error ||
                    `${response.status} ${response.statusText}`;
                const error = new Error(String(message));
                error.status = response.status;
                throw error;
            }
            return data;
        };
        const bodyJSON = (value) => ({
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(value),
        });
        const showMessage = (title, message) => {
            $("message-title").textContent = title;
            $("message-body").textContent = message;
            openDialog($("message-dialog"));
        };
        const formatBytes = (bytes) => {
            if (!Number.isFinite(bytes) || bytes < 1024) return `${bytes || 0} B`;
            const units = ["KiB", "MiB", "GiB", "TiB"];
            let n = bytes;
            let i = -1;
            do {
                n /= 1024;
                i++;
            } while (n >= 1024 && i < units.length - 1);
            return `${n.toFixed(n >= 10 ? 0 : 1)} ${units[i]}`;
        };
        const formatDate = (seconds) => {
            const date = new Date(Number(seconds || 0) * 1000);
            return Number.isFinite(date.getTime()) && date.getTime() > 0
                ? date.toLocaleString()
                : "—";
        };
        const readResume = () => {
            const value = JSON.parse(localStorage.getItem(RESUME_KEY) || "{}");
            if (!value || Array.isArray(value) || typeof value !== "object")
                throw new Error("本地恢复记录损坏，请导出后清理");
            return value;
        };
        const writeResume = (records) => {
            localStorage.setItem(RESUME_KEY, JSON.stringify(records));
            renderResumeRecords();
        };
        // 抽样指纹防止误选名称、大小相同的另一个文件；它不是整文件校验和。
        async function fingerprint(file, path) {
            let hash1 = 2166136261,
                hash2 = 5381;
            for (const chunk of [
                file.slice(0, 65536),
                file.slice(Math.max(0, file.size - 65536)),
            ]) {
                for (const byte of new Uint8Array(await chunk.arrayBuffer())) {
                    hash1 = Math.imul(hash1 ^ byte, 16777619);
                    hash2 = Math.imul(hash2, 33) ^ byte;
                }
            }
            return JSON.stringify([
                path,
                file.name,
                file.size,
                file.lastModified,
                (hash1 >>> 0).toString(16),
                (hash2 >>> 0).toString(16),
            ]);
        }
        const pathForFile = (file) => file.webkitRelativePath || file.name;
        const uploadPath = (relative) =>
            state.path ? `${state.path}/${relative}` : relative;
        function choose(title, message, choices) {
            return new Promise((resolve) => {
                const dialog = $("choice-dialog");
                $("choice-title").textContent = title;
                $("choice-body").textContent = message;
                $("choice-actions").replaceChildren();
                const finish = (value) => {
                    closeDialog(dialog);
                    dialog.oncancel = null;
                    resolve(value);
                };
                choices.forEach(([value, label, style]) => {
                    const button = document.createElement("button");
                    button.textContent = label;
                    button.className = style || "";
                    button.onclick = () => finish(value);
                    $("choice-actions").append(button);
                });
                dialog.oncancel = (event) => {
                    event.preventDefault();
                    finish(null);
                };
                openDialog(dialog);
            });
        }

        function renderBreadcrumbs() {
            const root = document.createElement("button");
            root.className = `crumb${state.path ? "" : " current"}`;
            root.textContent = "根目录";
            root.onclick = () => openPath("");
            $("breadcrumbs").replaceChildren(root);
            let accumulated = "";
            state.path
                .split("/")
                .filter(Boolean)
                .forEach((part, index, parts) => {
                    accumulated = accumulated ? `${accumulated}/${part}` : part;
                    const separator = document.createElement("span");
                    separator.textContent = " / ";
                    $("breadcrumbs").append(separator);
                    const crumb = document.createElement("button");
                    crumb.className = `crumb${index === parts.length - 1 ? " current" : ""}`;
                    crumb.textContent = part;
                    const target = accumulated;
                    crumb.onclick = () => openPath(target);
                    $("breadcrumbs").append(crumb);
                });
        }
        function renderEntries() {
            const tbody = $("file-list");
            tbody.replaceChildren();
            if (!state.entries.length) {
                const row = document.createElement("tr");
                const cell = document.createElement("td");
                cell.colSpan = 5;
                cell.className = "empty";
                cell.textContent = "目录为空";
                row.append(cell);
                tbody.append(row);
                return;
            }
            state.entries.forEach((entry) => {
                const row = document.createElement("tr");
                const name = document.createElement("td");
                name.className = "name";
                const open = document.createElement("button");
                open.className = "name-button";
                open.textContent = entry.name;
                open.onclick = () =>
                    entry.kind === "directory"
                        ? openPath(entry.path)
                        : openFile(entry.path);
                name.append(open);
                row.append(name);
                const kind = document.createElement("td");
                kind.textContent = entry.kind === "directory" ? "文件夹" : "文件";
                row.append(kind);
                const size = document.createElement("td");
                size.textContent =
                    entry.kind === "directory"
                        ? "—"
                        : formatBytes(Number(entry.size));
                row.append(size);
                const modified = document.createElement("td");
                modified.textContent = formatDate(entry.modifiedAt);
                row.append(modified);
                const actions = document.createElement("td");
                actions.className = "row-actions";
                if (entry.kind === "file") {
                    const preview = document.createElement("button");
                    preview.textContent = "打开";
                    preview.onclick = () => openFile(entry.path);
                    actions.append(preview);
                    const down = document.createElement("button");
                    down.textContent = "下载";
                    down.onclick = () => download(entry.path);
                    actions.append(down);
                } else {
                    const enter = document.createElement("button");
                    enter.textContent = "打开";
                    enter.onclick = () => openPath(entry.path);
                    actions.append(enter);
                    const downFolder = document.createElement("button");
                    downFolder.textContent = "逐项下载";
                    downFolder.className = "secondary";
                    downFolder.onclick = () => prepareFolderDownload(entry);
                    actions.append(downFolder);
                }
                const move = document.createElement("button");
                move.textContent = "移动";
                move.className = "secondary";
                move.onclick = () => moveEntry(entry);
                actions.append(move);
                const remove = document.createElement("button");
                remove.textContent = "删除";
                remove.className = "danger";
                remove.onclick = () => deleteEntry(entry);
                actions.append(remove);
                row.append(actions);
                tbody.append(row);
            });
        }
        async function openPath(path) {
            const requestID = ++state.directoryRequest;
            state.path = path;
            renderBreadcrumbs();
            $("file-list").innerHTML =
                '<tr><td colspan="5" class="empty">正在读取…</td></tr>';
            try {
                const result = await json(
                    `/api/v1/files/list?path=${encodeURIComponent(path)}`,
                );
                if (requestID !== state.directoryRequest) return;
                state.entries = Array.isArray(result?.entries)
                    ? result.entries
                    : [];
                renderEntries();
            } catch (error) {
                if (requestID !== state.directoryRequest) return;
                state.entries = [];
                renderEntries();
                showMessage("读取目录失败", error.message);
            }
        }
        async function refresh() {
            try {
                const result = await json("/api/v1/status");
                $("service-state").textContent = result?.running
                    ? "服务运行中 · 传输期间请保持 MeloNX 前台"
                    : "服务未运行";
            } catch (error) {
                $("service-state").textContent =
                    `服务状态读取失败：${error.message}`;
            }
            await openPath(state.path);
        }
        function openFile(path) {
            window.open(
                `/api/v1/files/open?path=${encodeURIComponent(path)}`,
                "_blank",
                "noopener",
            );
        }
        function download(path) {
            const query = `path=${encodeURIComponent(path)}`;
            const link = document.createElement("a");
            link.href = `/api/v1/files/download?${query}`;
            link.download = path.split("/").pop() || "download";
            link.target = "_blank";
            document.body.append(link);
            link.click();
            link.remove();
        }
        async function collectFiles(path, output = []) {
            const result = await json(
                `/api/v1/files/list?path=${encodeURIComponent(path)}`,
            );
            for (const entry of result?.entries || []) {
                if (entry.kind === "directory")
                    await collectFiles(entry.path, output);
                else output.push(entry);
            }
            return output;
        }
        async function prepareFolderDownload(entry) {
            const list = $("downloads-list");
            list.textContent = "正在读取目录清单…";
            state.folderDownloadEntries = [];
            $("downloads-all").disabled = true;
            openDialog($("downloads-dialog"));
            try {
                state.folderDownloadEntries = await collectFiles(entry.path);
                list.replaceChildren();
                if (!state.folderDownloadEntries.length) {
                    list.textContent = "目录为空";
                    return;
                }
                state.folderDownloadEntries.forEach((file) => {
                    const item = document.createElement("a");
                    item.href = `/api/v1/files/download?path=${encodeURIComponent(file.path)}`;
                    item.download = file.name;
                    item.textContent = `${file.path} · ${formatBytes(Number(file.size))}`;
                    list.append(item);
                });
                $("downloads-all").disabled = false;
            } catch (error) {
                list.textContent = `读取失败：${error.message}`;
            }
        }
        function downloadFolderItems() {
            const files = state.folderDownloadEntries.slice();
            let index = 0;
            const next = () => {
                if (index >= files.length) return;
                download(files[index++].path);
                window.setTimeout(next, 700);
            };
            next();
        }
        async function mkdir() {
            const name = window.prompt("新文件夹名称（只填写当前目录下的名称）");
            if (!name) return;
            if (name === "." || name === ".." || /[\\/\0]/.test(name)) {
                showMessage("名称无效", "文件夹名称不能包含路径分隔符。");
                return;
            }
            try {
                await json(
                    "/api/v1/files/mkdir",
                    bodyJSON({ path: state.path ? `${state.path}/${name}` : name }),
                );
                await refresh();
            } catch (error) {
                showMessage("新建文件夹失败", error.message);
            }
        }
        async function deleteEntry(entry) {
            try {
                const preview = await json(
                    "/api/v1/files/delete/prepare",
                    bodyJSON({ path: entry.path }),
                );
                const count = preview?.itemCount
                    ? `共 ${preview.itemCount} 项，约 ${formatBytes(Number(preview.totalBytes || 0))}。`
                    : "";
                const warning =
                    entry.kind === "directory"
                        ? "此操作会递归删除文件夹内的全部内容，且无法恢复。"
                        : "此操作无法恢复。";
                if (
                    !window.confirm(
                        `确定删除“${entry.name}”？\n${warning}\n${count}`,
                    )
                )
                    return;
                await json("/api/v1/files/item", {
                    method: "DELETE",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        path: entry.path,
                        confirmationToken: preview.confirmationToken,
                    }),
                });
                await refresh();
            } catch (error) {
                showMessage("删除失败", error.message);
            }
        }
        async function moveEntry(entry) {
            const destination = window.prompt(
                "输入目标相对路径（包含新名称）",
                entry.path,
            );
            if (!destination || destination === entry.path) return;
            try {
                let conflict = "ask",
                    preview;
                const request = () =>
                    json(
                        "/api/v1/files/move/prepare",
                        bodyJSON({
                            sourcePath: entry.path,
                            destinationPath: destination,
                            conflict,
                        }),
                    );
                try {
                    preview = await request();
                } catch (error) {
                    if (error.status !== 409) throw error;
                    const choices =
                        entry.kind === "directory"
                            ? [
                                  ["mergeDirectory", "合并目录"],
                                  ["replaceDirectory", "替换整个目录", "danger"],
                                  ["skip", "跳过", "secondary"],
                              ]
                            : [
                                  ["replaceFile", "替换文件", "danger"],
                                  ["skip", "跳过", "secondary"],
                              ];
                    conflict = await choose(
                        "目标已存在",
                        "合并目录会保留目标中的其他项目，并覆盖同名文件；替换整个目录会删除原目录内容。",
                        [...choices, [null, "取消", "secondary"]],
                    );
                    if (!conflict || conflict === "skip") return;
                    preview = await request();
                }
                if (
                    !window.confirm(
                        `确认移动“${entry.path}”到“${destination}”？\n${conflict === "replaceDirectory" ? "原目标目录将被整体替换，无法恢复。" : "请确认源和目标路径。"}`,
                    )
                )
                    return;
                await json(
                    "/api/v1/files/move",
                    bodyJSON({
                        sourcePath: entry.path,
                        destinationPath: destination,
                        conflict,
                        confirmationToken: preview.confirmationToken,
                    }),
                );
                await refresh();
            } catch (error) {
                showMessage("移动失败", error.message);
            }
        }
        function transferRow(id, label) {
            let item = state.transfers.get(id);
            if (!item) {
                item = { id, label, done: 0, total: 0, status: "排队中" };
                state.transfers.set(id, item);
            }
            return item;
        }
        function renderTransfers() {
            const list = $("transfer-list");
            list.replaceChildren();
            state.transfers.forEach((item) => {
                const row = document.createElement("div");
                row.className = "transfer-item";
                const label = document.createElement("span");
                label.textContent = item.label;
                row.append(label);
                const status = document.createElement("span");
                status.className = "muted";
                status.textContent = item.status;
                row.append(status);
                const progress = document.createElement("progress");
                progress.max = item.total || 1;
                progress.value = Math.min(
                    item.total || 1,
                    item.done + (item.inFlight || 0),
                );
                row.append(progress);
                const percent = document.createElement("span");
                percent.className = "muted";
                percent.textContent = item.total
                    ? `${Math.floor(((item.done + (item.inFlight || 0)) * 100) / item.total)}%`
                    : "—";
                row.append(percent);
                list.append(row);
            });
            $("transfer-panel").hidden = state.transfers.size === 0;
        }
        function uploadChunk(snapshot, offset, endExclusive, file, transfer) {
            return new Promise((resolve, reject) => {
                const xhr = new XMLHttpRequest();
                state.activeXHR = xhr;
                xhr.open(
                    "PUT",
                    `/api/v1/transfers/uploads/${encodeURIComponent(snapshot.uploadID)}`,
                );
                xhr.withCredentials = true;
                xhr.setRequestHeader("Authorization", `Bearer ${token}`);
                xhr.setRequestHeader("X-Resume-Token", snapshot.resumeToken);
                xhr.setRequestHeader("Content-Type", "application/octet-stream");
                xhr.setRequestHeader(
                    "Content-Range",
                    `bytes ${offset}-${endExclusive - 1}/${file.size}`,
                );
                xhr.upload.onprogress = (event) => {
                    transfer.inFlight = event.lengthComputable ? event.loaded : 0;
                    renderTransfers();
                };
                xhr.onerror = () => {
                    transfer.inFlight = 0;
                    reject(new Error("网络连接中断，当前 500 MiB 分片尚未确认"));
                };
                xhr.ontimeout = () => {
                    transfer.inFlight = 0;
                    reject(
                        new Error("当前分片请求超时，重试时会从服务器确认偏移继续"),
                    );
                };
                xhr.onabort = () => {
                    transfer.inFlight = 0;
                    reject(new Error("已暂停，当前分片将在继续时重新核对"));
                };
                xhr.onloadend = () => {
                    if (state.activeXHR === xhr) state.activeXHR = null;
                };
                xhr.onload = () => {
                    transfer.inFlight = 0;
                    let value = null;
                    try {
                        value = JSON.parse(xhr.responseText || "null");
                    } catch (_) {
                        /* 由状态码错误处理 */
                    }
                    if (xhr.status < 200 || xhr.status >= 300) {
                        const message =
                            value?.error?.message ||
                            value?.error ||
                            `${xhr.status} ${xhr.statusText}`;
                        const error = new Error(String(message));
                        error.status = xhr.status;
                        reject(error);
                    } else if (!value) reject(new Error("服务器没有返回分片状态"));
                    else resolve(value);
                };
                xhr.send(file.slice(offset, endExclusive));
            });
        }
        async function uploadOne(file, destination) {
            const id = await fingerprint(file, destination);
            const transfer = transferRow(id, destination);
            transfer.total = file.size;
            transfer.status = "准备中";
            renderTransfers();
            let record = readResume()[id],
                snapshot = null;
            try {
                if (record) {
                    try {
                        snapshot = await json(
                            `/api/v1/transfers/uploads/${encodeURIComponent(record.uploadID)}`,
                            { headers: { "X-Resume-Token": record.resumeToken } },
                        );
                    } catch (error) {
                        if (error.status !== 404) throw error;
                        if (
                            !window.confirm(
                                `“${destination}”的服务器临时会话已不存在，重新上传？`,
                            )
                        ) {
                            transfer.status = "已跳过";
                            renderTransfers();
                            return;
                        }
                        const records = readResume();
                        delete records[id];
                        writeResume(records);
                        record = null;
                    }
                }
                if (!snapshot) {
                    let conflict = "ask";
                    const create = () =>
                        json(
                            "/api/v1/transfers/uploads",
                            bodyJSON({
                                path: destination,
                                size: file.size,
                                sha256: null,
                                conflict,
                                clientFingerprint: id,
                            }),
                        );
                    try {
                        snapshot = await create();
                    } catch (error) {
                        if (error.status !== 409) throw error;
                        conflict = await choose(
                            "同名文件已存在",
                            `“${destination}”已存在。覆盖成功前会保留原文件。`,
                            [
                                ["replace", "覆盖", "danger"],
                                ["skip", "跳过", "secondary"],
                                [null, "暂停批次", "secondary"],
                            ],
                        );
                        if (!conflict) {
                            state.pauseRequested = true;
                            transfer.status = "已暂停";
                            renderTransfers();
                            return;
                        }
                        if (conflict === "skip") {
                            transfer.status = "已跳过";
                            renderTransfers();
                            return;
                        }
                        snapshot = await create();
                    }
                    record = {
                        uploadID: snapshot.uploadID,
                        resumeToken: snapshot.resumeToken,
                        path: destination,
                        size: file.size,
                        lastModified: file.lastModified,
                        name: file.name,
                        clientFingerprint: id,
                        nextOffset: snapshot.nextOffset || 0,
                    };
                    const records = readResume();
                    records[id] = record;
                    writeResume(records);
                }
                if (
                    snapshot.destinationPath !== destination ||
                    Number(snapshot.totalBytes) !== file.size ||
                    (snapshot.clientFingerprint &&
                        snapshot.clientFingerprint !== id)
                )
                    throw new Error("恢复会话与所选文件不一致，已拒绝续传");
                let offset = Number(snapshot.nextOffset);
                if (
                    !Number.isSafeInteger(offset) ||
                    offset < 0 ||
                    offset > file.size
                )
                    throw new Error("服务器返回的恢复偏移无效");
                transfer.done = offset;
                transfer.status = "上传中";
                renderTransfers();
                while (offset < file.size) {
                    if (state.pauseRequested) {
                        transfer.status = "已暂停";
                        renderTransfers();
                        return;
                    }
                    const endExclusive = Math.min(file.size, offset + CHUNK_SIZE);
                    const next = await uploadChunk(
                        snapshot,
                        offset,
                        endExclusive,
                        file,
                        transfer,
                    );
                    if (Number(next.nextOffset) !== endExclusive)
                        throw new Error(
                            "服务器返回的分片偏移异常，请重新选择原文件恢复",
                        );
                    offset = endExclusive;
                    snapshot = next;
                    transfer.done = offset;
                    const records = readResume();
                    records[id].nextOffset = offset;
                    writeResume(records);
                    renderTransfers();
                }
                transfer.status = "提交中";
                renderTransfers();
                if (snapshot.state !== "completed")
                    await json(
                        `/api/v1/transfers/uploads/${encodeURIComponent(snapshot.uploadID)}/complete`,
                        {
                            ...bodyJSON({}),
                            headers: {
                                "Content-Type": "application/json",
                                "X-Resume-Token": snapshot.resumeToken,
                            },
                        },
                    );
                const records = readResume();
                delete records[id];
                writeResume(records);
                transfer.done = file.size;
                transfer.status = "已完成";
                renderTransfers();
            } catch (error) {
                transfer.status = `已暂停：${error.message}`;
                renderTransfers();
                state.pauseRequested = true;
                throw error;
            }
        }
        async function uploadFiles(files, explicitDestination = null) {
            const list = Array.from(files || []);
            if (!list.length) return;
            if (state.busy) {
                showMessage("上传进行中", "请等待当前批次结束或暂停后再添加文件。");
                return;
            }
            state.busy = true;
            state.pauseRequested = false;
            const basePath = state.path;
            $("pause-uploads").hidden = false;
            $("pause-uploads").disabled = false;
            $("pause-uploads").textContent = "暂停上传";
            try {
                for (const file of list) {
                    if (state.pauseRequested) break;
                    const relative = pathForFile(file);
                    const destination =
                        explicitDestination ||
                        (basePath ? `${basePath}/${relative}` : relative);
                    await uploadOne(file, destination);
                }
            } catch (error) {
                $("transfer-hint").textContent =
                    "上传已暂停，重新选择原文件可继续。";
            } finally {
                state.busy = false;
                $("pause-uploads").hidden = true;
                renderResumeRecords();
                await refresh();
            }
        }
        function clearResume() {
            if (state.busy) {
                showMessage("请先暂停上传", "上传进行中不能清理恢复记录。");
                return;
            }
            if (
                window.confirm(
                    "清理本浏览器保存的上传恢复记录？服务器上的临时分片不会删除。",
                )
            ) {
                localStorage.removeItem(RESUME_KEY);
                renderResumeRecords();
                showMessage(
                    "已清理",
                    "后续上传将从新会话开始；服务器临时分片会按过期策略清理。",
                );
            }
        }
        function exportResume() {
            const data = JSON.stringify(readResume(), null, 2);
            const link = document.createElement("a");
            link.href = URL.createObjectURL(
                new Blob([data], { type: "application/json" }),
            );
            link.download = "melo-upload-resume.json";
            link.click();
            URL.revokeObjectURL(link.href);
        }
        function validRecord(key, value) {
            return (
                key.startsWith("[") &&
                key.length < 16384 &&
                value &&
                typeof value === "object" &&
                typeof value.path === "string" &&
                value.path.length <= 8192 &&
                typeof value.name === "string" &&
                typeof value.uploadID === "string" &&
                /^[0-9a-f-]{36}$/i.test(value.uploadID) &&
                typeof value.resumeToken === "string" &&
                value.resumeToken.length <= 256 &&
                Number.isSafeInteger(value.size) &&
                value.size >= 0 &&
                Number.isFinite(value.lastModified) &&
                value.clientFingerprint === key
            );
        }
        function importResume(file) {
            if (state.busy) {
                showMessage("请先暂停上传", "上传进行中不能导入恢复记录。");
                return;
            }
            if (file.size > 2 * 1024 * 1024) {
                showMessage("导入失败", "恢复记录文件超过 2 MiB。");
                return;
            }
            const reader = new FileReader();
            reader.onerror = () =>
                showMessage("导入失败", "无法读取所选记录文件。");
            reader.onload = () => {
                try {
                    const incoming = JSON.parse(String(reader.result));
                    if (
                        !incoming ||
                        Array.isArray(incoming) ||
                        typeof incoming !== "object"
                    )
                        throw new Error("记录格式无效");
                    const merged = readResume();
                    for (const [key, value] of Object.entries(incoming)) {
                        if (!validRecord(key, value))
                            throw new Error("记录字段不符合当前格式");
                        merged[key] = value;
                    }
                    writeResume(merged);
                    showMessage(
                        "已导入",
                        "恢复记录已合并。请重新选择对应的原文件继续上传。",
                    );
                } catch (error) {
                    showMessage("导入失败", error.message);
                }
            };
            reader.readAsText(file);
        }
        async function discardResume(key, record) {
            if (
                state.busy ||
                !window.confirm(
                    `放弃“${record.path}”的未完成上传并删除服务器临时分片？正式文件不会受影响。`,
                )
            )
                return;
            try {
                await json(
                    `/api/v1/transfers/uploads/${encodeURIComponent(record.uploadID)}`,
                    {
                        method: "DELETE",
                        headers: { "X-Resume-Token": record.resumeToken },
                    },
                );
            } catch (error) {
                if (error.status !== 404) {
                    showMessage("放弃失败", error.message);
                    return;
                }
            }
            const current = readResume();
            delete current[key];
            writeResume(current);
        }
        function renderResumeRecords() {
            const records = readResume(),
                panel = $("resume-panel"),
                list = $("resume-list");
            list.replaceChildren();
            const values = Object.entries(records);
            panel.hidden = values.length === 0;
            values.forEach(([key, record]) => {
                const row = document.createElement("div");
                row.className = "resume-item";
                const text = document.createElement("span");
                text.textContent = `${record.path || key} · 已确认 ${formatBytes(Number(record.nextOffset || 0))} / ${formatBytes(Number(record.size || 0))}`;
                row.append(text);
                const actions = document.createElement("div");
                actions.className = "top-actions";
                const resume = document.createElement("button");
                resume.textContent = "选择原文件继续";
                resume.disabled = state.busy;
                resume.onclick = () => {
                    const picker = document.createElement("input");
                    picker.type = "file";
                    picker.onchange = async () => {
                        const file = picker.files[0];
                        if (!file) return;
                        if ((await fingerprint(file, record.path)) !== key) {
                            showMessage(
                                "文件不一致",
                                "名称、大小、修改时间或头尾内容与原上传不一致，已拒绝续传。",
                            );
                            return;
                        }
                        await uploadFiles([file], record.path);
                    };
                    picker.click();
                };
                actions.append(resume);
                const remove = document.createElement("button");
                remove.textContent = "放弃";
                remove.className = "danger";
                remove.disabled = state.busy;
                remove.onclick = () => discardResume(key, record);
                actions.append(remove);
                row.append(actions);
                list.append(row);
            });
        }
        async function resumeTools() {
            const action = await choose(
                "恢复记录",
                "记录包含恢复凭据，请只在自己的设备间传递。",
                [
                    ["export", "导出"],
                    ["import", "导入"],
                    ["clear", "清理本地记录", "danger"],
                    [null, "取消", "secondary"],
                ],
            );
            if (action === "export") exportResume();
            else if (action === "import") $("resume-import").click();
            else if (action === "clear") clearResume();
        }
        function showHelp() {
            showMessage(
                "使用说明",
                "上传采用 500 MiB 有序分片并串行发送，单片断线时只重传当前分片。网页重开后重新选择原文件即可从已确认偏移继续。未完成上传保留为 .melo-upload.part。文件夹上传保留相对路径，浏览器选择器无法提供空文件夹。下载由浏览器流式处理；断点恢复取决于浏览器或 Range 下载器，网页无法更改浏览器的下载临时后缀。建议使用近期版本的 Chrome、Edge、Firefox 或 Safari 15.4 及以上。",
            );
        }
        async function initialize() {
            try {
                await json("/api/v1/auth", bodyJSON({ token }));
                await refresh();
            } catch (error) {
                $("service-state").textContent = `鉴权失败：${error.message}`;
                showMessage(
                    "无法连接服务",
                    "请从 MeloNX 菜单重新复制地址并打开；服务停止后旧地址会失效。",
                );
            }
        }
        $("refresh").onclick = refresh;
        $("mkdir").onclick = mkdir;
        $("resume-tools").onclick = resumeTools;
        $("pause-uploads").onclick = () => {
            state.pauseRequested = true;
            $("pause-uploads").disabled = true;
            $("pause-uploads").textContent = "正在暂停…";
            if (state.activeXHR) state.activeXHR.abort();
        };
        $("downloads-all").onclick = downloadFolderItems;
        $("downloads-close").onclick = () => closeDialog($("downloads-dialog"));
        $("resume-import").onchange = (event) => {
            if (event.target.files[0]) importResume(event.target.files[0]);
            event.target.value = "";
        };
        $("help").onclick = showHelp;
        $("file-input").onchange = (event) => {
            uploadFiles(event.target.files);
            event.target.value = "";
        };
        $("folder-input").onchange = (event) => {
            uploadFiles(event.target.files);
            event.target.value = "";
        };
        renderBreadcrumbs();
        renderResumeRecords();
        initialize();
    })();
    """#
}
