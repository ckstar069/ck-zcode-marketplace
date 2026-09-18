// webgpt-zcode-bridge — Linux CDP core（5C 起：one-shot cdp-client 与持久 cdp-broker 共享的
// 已验证 CDP 机制，语义与 Batch 3/4/5 已动态验收的实现逐点一致，不重写任何 binding/safety 语义）。
//
// 职责（ARCHITECTURE §5/§7 + spec/cdp-broker-contract.md §10）：
//   DevToolsActivePort 读取（stale/malformed 归类）→ browser WebSocket（Allow-hint + 有界超时）
//   → Browser.getVersion → Target.getTargets（exact WebGPT origin predicate）
//   → Target.createTarget（仅 exact origin）→ Target.attachToTarget(flatten)
//   → Runtime.evaluate（exact full-URL filter + at-most-once + post-eval getTargetInfo fail-closed）。
// 本文件禁止出现 WebGPT 业务语义（endpoint/selector/auth/composer）——属 src/common/page/*。
//
// 安全不变量（不可回退）：
//   - startsWith origin / substring filter / pre-eval cached URL 一律禁止；
//   - Runtime.evaluate request 一旦写出：timeout/WS drop/protocol error/response loss
//     全部 terminal，绝不重放（Batch 3B 冻结；5C §9 跨 broker 边界继续成立）；
//   - getTargetInfo 失败或无有效 URL → fail closed（Batch hardening FINAL）。
//
// 环境变量（由使用者透传）：
//   WZB_CDP_USER_DATA_DIR / WZB_CDP_CONNECT_TIMEOUT / WZB_CDP_CMD_TIMEOUT / WZB_CDP_EVAL_TIMEOUT
//   WZB_CDP_HOST_PROBE_TIMEOUT（空 filter read-host 固定无副作用 probe；默认 2s）

import { readFileSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';

export const WZB_ORIGIN = 'https://chatgpt.com';
export const READ_HOST_HEALTH_PROBE_EXPRESSION = '1';

export class CdpError extends Error {
  constructor(category, reason) { super(reason); this.category = category; }
}

function headerValues(value) {
  if (Array.isArray(value)) return value;
  return typeof value === 'string' ? [value] : [];
}

function asciiLower(value) {
  return value.replace(/[A-Z]/g, c => String.fromCharCode(c.charCodeAt(0) + 32));
}

function exactAsciiHeaderValue(value, expected) {
  const values = headerValues(value);
  return values.length === 1 && asciiLower(values[0].trim()) === expected;
}

function headerTokenListContains(value, expected) {
  return headerValues(value).some(v => v.split(',')
    .some(token => asciiLower(token.trim()) === expected));
}

function hasNonEmptyHeader(value) {
  return headerValues(value).some(v => v.trim() !== '');
}

// 精确 origin predicate（对齐 Windows Test-WzbWebgptUrl）：
// https + host 精确等于 chatgpt.com + 默认 HTTPS 端口（缺省或显式 :443）。
export function isWebgptPageUrl(u) {
  if (typeof u !== 'string' || u === '') return false;
  let m;
  try { m = new URL(u); } catch (e) { return false; }
  return m.protocol === 'https:' && m.hostname === 'chatgpt.com' && (m.port === '' || m.port === '443');
}

// DevToolsActivePort 读取：文件缺失/畸形 → remote_debugging_unavailable（stale 残留由连接阶段拒绝）。
export function readEndpoint(udd) {
  let text;
  try {
    text = readFileSync(`${udd}/DevToolsActivePort`, 'utf8');
  } catch (e) {
    throw new CdpError('remote_debugging_unavailable', `DevToolsActivePort not readable under ${udd}: ${e.code || e.message}`);
  }
  const lines = text.split('\n');
  const port = (lines[0] || '').trim();
  const path = (lines[1] || '').trim();
  if (!/^[0-9]{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535 || !path.startsWith('/')) {
    throw new CdpError('remote_debugging_unavailable', `DevToolsActivePort malformed (port='${port}', path=${path ? 'present' : 'missing'})`);
  }
  return { url: `ws://127.0.0.1:${port}${path}`, port };
}

// Node 内建 WebSocket 在 CONNECTING 状态没有公开的 abort/terminate API；close() 也不会
// 可靠终止仍待浏览器 Allow 的 HTTP Upgrade。这里仅实现本 capability 所需的 loopback ws://
// 客户端，以便 connect timeout/cancel 能精确 destroy 唯一底层 request/socket。
class LoopbackWebSocket {
  constructor(rawUrl) {
    const url = new URL(rawUrl);
    if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1') {
      throw new Error('CDP WebSocket must use ws://127.0.0.1');
    }
    this.readyState = 0; // CONNECTING
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
    this._request = null;
    this._connectingSocket = null;
    this._socket = null;
    this._buffer = Buffer.alloc(0);
    this._fragments = [];
    this._fragmentOpcode = 0;
    this._closeEmitted = false;

    const key = randomBytes(16).toString('base64');
    const req = httpRequest({
      hostname: '127.0.0.1',
      port: Number(url.port),
      path: `${url.pathname}${url.search}`,
      method: 'GET',
      agent: false,
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': key,
      },
    });
    this._request = req;
    req.once('socket', (socket) => { this._connectingSocket = socket; });
    req.once('upgrade', (res, socket, head) => {
      if (this.readyState !== 0) { socket.destroy(); return; }
      const expected = createHash('sha1')
        .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
        .digest('base64');
      const validUpgrade = exactAsciiHeaderValue(res.headers.upgrade, 'websocket');
      const validConnection = headerTokenListContains(res.headers.connection, 'upgrade');
      const validAccept = res.headers['sec-websocket-accept'] === expected;
      const unsolicitedExtension = hasNonEmptyHeader(res.headers['sec-websocket-extensions']);
      const unsolicitedProtocol = hasNonEmptyHeader(res.headers['sec-websocket-protocol']);
      if (res.statusCode !== 101 || !validUpgrade || !validConnection || !validAccept
          || unsolicitedExtension || unsolicitedProtocol) {
        socket.destroy();
        this._fail(new Error('invalid WebSocket upgrade response'));
        return;
      }
      this._request = null;
      this._connectingSocket = null;
      this._socket = socket;
      this.readyState = 1; // OPEN
      socket.setNoDelay(true);
      socket.on('data', (chunk) => this._consume(chunk));
      socket.on('error', (e) => this._fail(e));
      socket.on('close', () => {
        this.readyState = 3;
        this._emitClose();
      });
      if (head && head.length) this._consume(head);
      try { if (this.onopen) this.onopen({}); } catch (e) { /* consumer owns callback errors */ }
    });
    req.once('response', (res) => {
      res.resume();
      this._fail(new Error(`WebSocket upgrade rejected with HTTP ${res.statusCode}`));
    });
    req.once('error', (e) => this._fail(e));
    req.end();
  }

  _encode(payload, opcode) {
    const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload));
    const mask = randomBytes(4);
    let header;
    if (body.length < 126) {
      header = Buffer.alloc(2); header[1] = 0x80 | body.length;
    } else if (body.length < 65536) {
      header = Buffer.alloc(4); header[1] = 0x80 | 126; header.writeUInt16BE(body.length, 2);
    } else {
      header = Buffer.alloc(10); header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(body.length), 2);
    }
    header[0] = 0x80 | opcode;
    const masked = Buffer.alloc(body.length);
    for (let i = 0; i < body.length; i++) masked[i] = body[i] ^ mask[i % 4];
    return Buffer.concat([header, mask, masked]);
  }

  _consume(chunk) {
    this._buffer = Buffer.concat([this._buffer, chunk]);
    for (;;) {
      if (this._buffer.length < 2) return;
      const b0 = this._buffer[0], b1 = this._buffer[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f, off = 2;
      if (len === 126) {
        if (this._buffer.length < 4) return;
        len = this._buffer.readUInt16BE(2); off = 4;
      } else if (len === 127) {
        if (this._buffer.length < 10) return;
        const n = this._buffer.readBigUInt64BE(2);
        if (n > BigInt(Number.MAX_SAFE_INTEGER)) { this._fail(new Error('WebSocket frame too large')); return; }
        len = Number(n); off = 10;
      }
      let mask = null;
      if (masked) {
        if (this._buffer.length < off + 4) return;
        mask = this._buffer.subarray(off, off + 4); off += 4;
      }
      if (this._buffer.length < off + len) return;
      let payload = this._buffer.subarray(off, off + len);
      this._buffer = this._buffer.subarray(off + len);
      if (mask) {
        const unmasked = Buffer.alloc(payload.length);
        for (let i = 0; i < payload.length; i++) unmasked[i] = payload[i] ^ mask[i % 4];
        payload = unmasked;
      }
      if (opcode === 0x8) {
        if (this.readyState === 1) {
          try { this._socket.write(this._encode(payload, 0x8)); } catch (e) { /* peer is closing */ }
        }
        this.readyState = 2;
        try { this._socket.end(); } catch (e) { /* ignore */ }
      } else if (opcode === 0x9) {
        if (this.readyState === 1) {
          try { this._socket.write(this._encode(payload, 0xA)); } catch (e) { /* ignore */ }
        }
      } else if (opcode === 0x1) {
        if (fin) this._emitMessage(payload);
        else { this._fragmentOpcode = opcode; this._fragments = [payload]; }
      } else if (opcode === 0x0 && this._fragmentOpcode === 0x1) {
        this._fragments.push(payload);
        if (fin) {
          const text = Buffer.concat(this._fragments);
          this._fragments = []; this._fragmentOpcode = 0;
          this._emitMessage(text);
        }
      }
    }
  }

  _emitMessage(payload) {
    try { if (this.onmessage) this.onmessage({ data: payload.toString('utf8') }); } catch (e) { /* ignore */ }
  }

  _emitClose() {
    if (this._closeEmitted) return;
    this._closeEmitted = true;
    try { if (this.onclose) this.onclose({}); } catch (e) { /* ignore */ }
  }

  _fail(error) {
    if (this.readyState === 3) return;
    this.readyState = 3;
    try { if (this._request) this._request.destroy(); } catch (e) { /* ignore */ }
    try { if (this._connectingSocket) this._connectingSocket.destroy(); } catch (e) { /* ignore */ }
    try { if (this._socket) this._socket.destroy(); } catch (e) { /* ignore */ }
    try { if (this.onerror) this.onerror({ error, message: error && error.message }); } catch (e) { /* ignore */ }
    this._emitClose();
  }

  send(text) {
    if (this.readyState !== 1 || !this._socket) throw new Error('WebSocket is not open');
    this._socket.write(this._encode(text, 0x1));
  }

  close() {
    if (this.readyState === 0) { this.terminate(); return; }
    if (this.readyState !== 1) return;
    this.readyState = 2;
    try { this._socket.end(this._encode(Buffer.alloc(0), 0x8)); } catch (e) { this.terminate(); }
  }

  terminate() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    try { if (this._request) this._request.destroy(); } catch (e) { /* ignore */ }
    try { if (this._connectingSocket) this._connectingSocket.destroy(); } catch (e) { /* ignore */ }
    try { if (this._socket) this._socket.destroy(); } catch (e) { /* ignore */ }
    this._emitClose();
  }
}

export class CdpCore {
  // opts: { udd, connectTimeoutMs, cmdTimeoutMs, evalTimeoutMs, hostProbeTimeoutMs,
  //         debug(msg), onState(state),
  //         onWsClose(), webSocketFactory(url) }；factory 仅供合成生命周期测试注入。
  constructor(opts = {}) {
    this.udd = opts.udd || `${process.env.HOME}/.config/google-chrome`;
    this.connectTimeoutMs = opts.connectTimeoutMs || (Number(process.env.WZB_CDP_CONNECT_TIMEOUT) || 90) * 1000;
    this.cmdTimeoutMs = opts.cmdTimeoutMs || (Number(process.env.WZB_CDP_CMD_TIMEOUT) || 30) * 1000;
    this.evalTimeoutMs = opts.evalTimeoutMs || (Number(process.env.WZB_CDP_EVAL_TIMEOUT) || 60) * 1000;
    const configuredProbeSeconds = Number(process.env.WZB_CDP_HOST_PROBE_TIMEOUT);
    this.hostProbeTimeoutMs = opts.hostProbeTimeoutMs
      || (Number.isFinite(configuredProbeSeconds) && configuredProbeSeconds > 0
        ? configuredProbeSeconds * 1000 : 2000);
    this.debug = opts.debug || (() => {});
    this.onState = opts.onState || (() => {});
    this.onWsClose = opts.onWsClose || (() => {});
    this.webSocketFactory = opts.webSocketFactory || ((url) => new LoopbackWebSocket(url));
    this.ws = null;
    this.wsOpen = false;
    this.epoch = 0; // 成功建立的 browser WebSocket 连接数（5C 验收观测量）
    this.connectAttempts = 0;
    this.currentConnectAttempt = null;
    this.lastConnectResult = null;
    this.lastConnectErrorCategory = null;
    this.stopping = false;
    this.nextId = 1;
    this.pending = new Map(); // cdp id → {res, rej, tmo, method}
    this.sessions = new Map(); // targetId → sessionId（同一 browser WS 生命周期内缓存）
    this._state('starting');
  }

  _state(s) { this.state = s; try { this.onState(s); } catch (e) { /* ignore */ } }

  connectionStatus() {
    const a = this.currentConnectAttempt;
    return {
      state: this.state,
      browser_connected: this.wsOpen,
      ws_epoch: this.epoch,
      browser_connect_attempts: this.connectAttempts,
      current_connect_attempt_id: a ? a.id : null,
      current_connect_started_at: a ? a.startedAt : null,
      last_connect_result: this.lastConnectResult,
      last_connect_error_category: this.lastConnectErrorCategory,
    };
  }

  _terminateSocket(ws) {
    if (!ws) return;
    try {
      if (typeof ws.terminate === 'function') ws.terminate();
      else ws.close();
    } catch (e) { /* already closed */ }
  }

  _failConnectAttempt(attempt, result, error) {
    if (!attempt || attempt.terminal) return;
    attempt.terminal = true;
    attempt.state = result;
    clearTimeout(attempt.timeout);
    if (this.currentConnectAttempt === attempt) this.currentConnectAttempt = null;
    this.lastConnectResult = result;
    this.lastConnectErrorCategory = error && error.category ? error.category : 'remote_debugging_unavailable';
    if (!this.stopping && !this.wsOpen) this._state('disconnected');
    this._terminateSocket(attempt.ws);
    attempt.reject(error);
  }

  connect() {
    if (this.wsOpen) return Promise.resolve();
    if (this.currentConnectAttempt) return this.currentConnectAttempt.promise;
    if (this.stopping) return Promise.reject(new CdpError('transport_failure', 'helper shutting down'));

    let ep;
    try { ep = readEndpoint(this.udd); }
    catch (e) {
      this.lastConnectResult = 'endpoint_error';
      this.lastConnectErrorCategory = e.category || 'remote_debugging_unavailable';
      if (!this.stopping) this._state('disconnected');
      return Promise.reject(e);
    }

    let resolveAttempt, rejectAttempt;
    const attempt = {
      id: ++this.connectAttempts,
      startedAt: new Date().toISOString(),
      startedMs: Date.now(),
      state: 'connecting',
      ws: null,
      timeout: null,
      terminal: false,
      promise: null,
      resolve: null,
      reject: null,
    };
    attempt.promise = new Promise((res, rej) => { resolveAttempt = res; rejectAttempt = rej; });
    attempt.resolve = resolveAttempt;
    attempt.reject = rejectAttempt;
    this.currentConnectAttempt = attempt;
    this._state('connecting');

    let ws;
    try { ws = this.webSocketFactory(ep.url); }
    catch (e) {
      this._failConnectAttempt(attempt, 'error', new CdpError('remote_debugging_unavailable',
        `cannot create loopback browser WebSocket for 127.0.0.1:${ep.port}: ${e.message || e}`));
      return attempt.promise;
    }
    attempt.ws = ws;

    ws.onmessage = (ev) => {
      if (this.ws !== ws || !this.wsOpen) return; // 旧 attempt 的迟到帧不得污染当前连接。
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      // CDP event（无 id）与通知一律忽略；只接受与 pending 关联的 command response。
      if (m && m.id !== undefined && this.pending.has(m.id)) {
        const p = this.pending.get(m.id);
        this.pending.delete(m.id);
        clearTimeout(p.tmo);
        if (m.error) p.rej(new CdpError('transport_failure', `CDP ${p.method}: ${m.error.message}`));
        else p.res(m.result);
      }
    };
    ws.onopen = () => {
      if (attempt.terminal || this.currentConnectAttempt !== attempt || this.stopping) {
        this._terminateSocket(ws);
        return;
      }
      attempt.terminal = true;
      attempt.state = 'success';
      clearTimeout(attempt.timeout);
      this.currentConnectAttempt = null;
      this.ws = ws;
      this.wsOpen = true;
      this.epoch += 1; // 只在真实成功 open 时推进。
      this.lastConnectResult = 'success';
      this.lastConnectErrorCategory = null;
      this._state('ready');
      this.debug(`connected (attempt ${attempt.id}, epoch ${this.epoch}, ${Date.now() - attempt.startedMs}ms)`);
      attempt.resolve();
    };
    ws.onerror = () => {
      if (attempt.terminal || this.currentConnectAttempt !== attempt) return;
      this._failConnectAttempt(attempt, 'error', new CdpError('remote_debugging_unavailable',
        `cannot connect to loopback endpoint 127.0.0.1:${ep.port} (connection refused/unusable — stale DevToolsActivePort or Remote Debugging disabled)`));
    };
    ws.onclose = () => {
      if (!attempt.terminal && this.currentConnectAttempt === attempt) {
        this._failConnectAttempt(attempt, 'error', new CdpError('remote_debugging_unavailable',
          `browser WebSocket closed before connect completed for 127.0.0.1:${ep.port}`));
        return;
      }
      if (this.ws === ws && this.wsOpen) {
        this.wsOpen = false;
        this.ws = null;
        if (!this.stopping) this._state('disconnected');
        this.debug('browser WebSocket closed');
        // 连接曾经成功后中断 → transport_failure（区别于连接阶段 remote_debugging_unavailable）。
        for (const p of this.pending.values()) {
          clearTimeout(p.tmo);
          p.rej(new CdpError('transport_failure', 'browser WebSocket closed mid-operation'));
        }
        this.pending.clear();
        this.sessions.clear();
        try { this.onWsClose(); } catch (e) { /* ignore */ }
      }
    };
    attempt.timeout = setTimeout(() => {
      this._failConnectAttempt(attempt, 'timeout', new CdpError('remote_debugging_unavailable',
        `browser WebSocket connect timeout after ${this.connectTimeoutMs / 1000}s; if Chrome shows an Allow dialog, approve Remote Debugging`));
    }, this.connectTimeoutMs);
    return attempt.promise;
  }

  _requireOpen() {
    if (!this.wsOpen) throw new CdpError('transport_failure', 'browser WebSocket is not open');
  }

  cdp(method, params = {}, sessionId, timeoutMs = this.cmdTimeoutMs) {
    this._requireOpen();
    const id = this.nextId++;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    this.ws.send(JSON.stringify(msg));
    return new Promise((res, rej) => {
      const tmo = setTimeout(() => {
        this.pending.delete(id);
        rej(new CdpError('transport_failure', `CDP ${method} timeout after ${timeoutMs / 1000}s`));
      }, timeoutMs);
      this.pending.set(id, { res, rej, tmo, method });
    });
  }

  async version() {
    const v = await this.cdp('Browser.getVersion');
    return { product: v.product, protocolVersion: v.protocolVersion };
  }

  async pages() {
    const r = await this.cdp('Target.getTargets');
    return (r.targetInfos || [])
      .filter(t => t.type === 'page' && isWebgptPageUrl(t.url))
      .map(t => ({ targetId: t.targetId, title: t.title || '', url: t.url }));
  }

  async open(url) {
    if (!isWebgptPageUrl(url)) {
      throw new CdpError('transport_failure', 'open_page refused non-chatgpt.com-origin URL (exact https default-port origin required)');
    }
    const r = await this.cdp('Target.createTarget', { url, background: true });
    return { targetId: r.targetId };
  }

  async _attach(targetId, timeoutMs = this.cmdTimeoutMs) {
    const a = await this.cdp('Target.attachToTarget', { targetId, flatten: true }, undefined, timeoutMs);
    this.sessions.set(targetId, a.sessionId);
    return a.sessionId;
  }

  // 空 filter 只读操作：每次 operation 按当前 Target.getTargets 顺序重新选择健康执行宿主；
  // probe 是写死的无副作用 control evaluation。probe/attach/origin recheck 可跳过失败 candidate，
  // 但一旦返回 host，后续 business evaluation 仍只有一次 dispatch 权。
  async _selectReadHost(candidates) {
    for (const target of candidates) {
      const started = Date.now();
      let sessionId = this.sessions.get(target.targetId);
      try {
        if (!sessionId) sessionId = await this._attach(target.targetId, this.hostProbeTimeoutMs);
        if (typeof sessionId !== 'string' || sessionId === '') {
          throw new CdpError('transport_failure', 'read-host attach returned no session id');
        }
        const probe = await this.cdp('Runtime.evaluate', {
          expression: READ_HOST_HEALTH_PROBE_EXPRESSION,
          awaitPromise: false,
          returnByValue: true,
        }, sessionId, this.hostProbeTimeoutMs);
        if (!probe || probe.exceptionDetails || !probe.result) {
          throw new CdpError('transport_failure', 'read-host health probe returned an invalid result');
        }
        const info = await this.cdp('Target.getTargetInfo', { targetId: target.targetId },
          undefined, this.hostProbeTimeoutMs);
        const currentUrl = (info && info.targetInfo && typeof info.targetInfo.url === 'string')
          ? info.targetInfo.url : '';
        if (!isWebgptPageUrl(currentUrl)) {
          this.sessions.delete(target.targetId);
          this.debug(`read-host skipped drifted target ${target.targetId.slice(0, 12)} (${Date.now() - started}ms)`);
          continue;
        }
        this.debug(`read-host selected target ${target.targetId.slice(0, 12)} (${Date.now() - started}ms)`);
        return { target, sessionId };
      } catch (e) {
        this.sessions.delete(target.targetId);
        this.debug(`read-host probe failed target ${target.targetId.slice(0, 12)} (${Date.now() - started}ms)`);
      }
    }
    throw new CdpError('transport_failure', 'no responsive chatgpt.com page available for read host');
  }

  // empty filter：健康 read-host selection；non-empty filter：exact full-URL binding（一次 stale 重枚举）。
  // 两条路径汇合后只允许单次 business Runtime.evaluate（at-most-once），再做 post-eval URL fail-closed。
  async evaluate(filter, js) {
    if (typeof js !== 'string' || js === '') throw new CdpError('transport_failure', 'eval: empty js');
    const f = typeof filter === 'string' ? filter : '';
    let target, sessionId;
    if (f === '') {
      const candidates = await this.pages();
      if (candidates.length === 0) {
        throw new CdpError('no_webgpt_page', `no open ${WZB_ORIGIN} page matches filter (exact URL equality required) '${f}'`);
      }
      ({ target, sessionId } = await this._selectReadHost(candidates));
    } else {
      const pick = (pages) => pages.find(p => p.url === f);
      let pages = await this.pages();
      target = pick(pages);
      if (!target) {
        pages = await this.pages();
        target = pick(pages);
      }
      if (!target) {
        throw new CdpError('no_webgpt_page', `no open ${WZB_ORIGIN} page matches filter (exact URL equality required) '${f}'`);
      }
      sessionId = this.sessions.get(target.targetId);
      if (!sessionId) sessionId = await this._attach(target.targetId);
    }
    let r;
    try {
      this.debug(`business evaluate dispatch target ${target.targetId.slice(0, 12)} filter=${f === '' ? 'empty' : 'exact'}`);
      r = await this.cdp('Runtime.evaluate',
        { expression: js, awaitPromise: true, returnByValue: true }, sessionId, this.evalTimeoutMs);
    } catch (e) {
      // at-most-once：request 已发出即 delivery 不可判定——绝不重放；session 弃置，
      // 由下一个 distinct operation 重新枚举/attach 恢复。
      this.sessions.delete(target.targetId);
      throw e;
    }
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      const desc = (d.exception && (d.exception.description || d.exception.value)) || d.text || 'unknown';
      throw new CdpError('transport_failure', `page evaluation exception: ${String(desc).slice(0, 300)}`);
    }
    // post-eval 当前 URL（control 命令，非第二次 JS evaluation）：失败/结构缺失均 fail closed，
    // 结果丢弃、无重放；session 视为不可信。
    let info;
    try {
      info = await this.cdp('Target.getTargetInfo', { targetId: target.targetId });
    } catch (e) {
      this.sessions.delete(target.targetId);
      throw new CdpError('transport_failure', 'post-eval Target.getTargetInfo failed after successful evaluation; result discarded, no replay');
    }
    const currentUrl = (info && info.targetInfo && typeof info.targetInfo.url === 'string') ? info.targetInfo.url : '';
    if (currentUrl === '') {
      this.sessions.delete(target.targetId);
      throw new CdpError('transport_failure', 'post-eval Target.getTargetInfo returned no valid current URL; result discarded, no replay');
    }
    const v = r.result ? r.result.value : undefined;
    return { url: currentUrl, value: typeof v === 'string' ? v : (v === undefined ? '' : JSON.stringify(v)) };
  }

  close() {
    this.stopping = true;
    this._state('stopping');
    if (this.currentConnectAttempt) {
      this._failConnectAttempt(this.currentConnectAttempt, 'cancelled', new CdpError('transport_failure', 'helper shutting down'));
    }
    this._terminateSocket(this.ws);
    this.ws = null;
    this.wsOpen = false;
    for (const p of this.pending.values()) {
      clearTimeout(p.tmo);
      p.rej(new CdpError('transport_failure', 'helper shutting down'));
    }
    this.pending.clear();
    this.sessions.clear();
  }
}

// ---- broker runtime 路径解析（broker 与 client 共用；可被 WZB_CDP_BROKER_SOCK 覆盖用于测试）----
export function resolveBrokerPaths() {
  if (process.env.WZB_CDP_BROKER_SOCK) {
    const sock = process.env.WZB_CDP_BROKER_SOCK;
    const dir = sock.replace(/\/[^/]*$/, '');
    return { dir, sock, lock: `${dir}/broker.lock`, pid: `${dir}/broker.pid` };
  }
  const base = process.env.XDG_RUNTIME_DIR || `${process.env.HOME}/.zcode/run`;
  const dir = `${base}/webgpt-zcode-bridge`;
  return { dir, sock: `${dir}/broker.sock`, lock: `${dir}/broker.lock`, pid: `${dir}/broker.pid` };
}

// pid 存活探测（仅同用户 namespace；ESRCH=不存在）。
export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return false; }
}
