#!/usr/bin/env node
// webgpt-zcode-bridge — Linux persistent CDP broker（Batch 5C；spec/cdp-broker-contract.md 冻结实现）。
//
// lifecycle：per-user、on-demand、long-lived；无 systemd/root/TCP。
//   many CLI invocations → 本 broker（UDS）→ one long-lived browser WebSocket → real Chrome。
//   browser WS 无 idle timeout（§5.1：避免无意义 re-approval）；仅在 Chrome WS close /
//   显式 shutdown / 进程退出时结束。Chrome WS 关闭后 broker 进程保留，state=disconnected，
//   下一个新 operation 触发重连（新 debugging session 可能再次 Allow，由 bootstrap 层处理）。
//
// IPC：Unix domain socket（默认 $XDG_RUNTIME_DIR/webgpt-zcode-bridge/broker.sock，回退
//   ~/.zcode/run/...；可经 WZB_CDP_BROKER_SOCK 覆盖用于测试）。parent dir 0700，socket 0600。
//
// 单例：O_EXCL lock file（broker.lock，内容=owner pid）。存在且 owner 存活 → 本进程作为
//   duplicate 立即退出；owner 已死（kill(pid,0)=ESRCH）→ 取得锁后清理自己 namespace 下的
//   stale socket/lock 再监听。绝不 pkill -f / killall / 宽泛删除。
//
// 并发（§8）：单条串行 browser-operation queue——多 client 可接入，但同一时刻只向 Chrome
//   发出一个 CDP operation；ping/status 不入队。broker 不跨 invocation 保存 composer ownership /
//   send authorization / message 状态。
//
// at-most-once（§9，最高优先级）：evaluate 一旦把 Runtime.evaluate 写入 browser WS，
//   timeout/WS drop/protocol error/response loss/客户端 IPC 断开全部 terminal failure，
//   绝不重放。in-memory op_id registry（FIFO 上限 1024）只用于同 op_id 的重复查询返回
//   已缓存结果——绝不是 durable queue，绝不触发重执行。
//
// 协议：UTF-8 JSON lines；request 必含唯一 op_id；response envelope 区分
//   ok / transport_failure / browser_unavailable / remote_debugging_unavailable / protocol_error。
//
// 日志（§14）：默认静默；WZB_CDP_DEBUG=1 时仅输出 state 转换 / op_id / method /
//   error category / timing 到 stderr——绝不记录 page JS / message / conversation 正文 /
//   token / cookie / authorization。
//
// 环境变量：WZB_CDP_BROKER_SOCK / WZB_CDP_USER_DATA_DIR / WZB_CDP_CONNECT_TIMEOUT /
// WZB_CDP_CMD_TIMEOUT / WZB_CDP_EVAL_TIMEOUT / WZB_CDP_DEBUG

import { createServer, connect } from 'node:net';
import { createInterface } from 'node:readline';
import { openSync, closeSync, writeSync, unlinkSync, mkdirSync, readFileSync, existsSync, chmodSync } from 'node:fs';
import { CdpCore, CdpError, resolveBrokerPaths, pidAlive } from './cdp-core.mjs';

const DEBUG = process.env.WZB_CDP_DEBUG === '1';
const dbg = (m) => { if (DEBUG) process.stderr.write(`wzb-broker: ${m}\n`); };

const PATHS = resolveBrokerPaths();
const OP_REGISTRY_LIMIT = 1024;

function fail(opId, category, reason) { return { op_id: opId, ok: false, category, reason }; }

// ---------- runtime dir + 单例锁 ----------
function prepareRuntimeDir() {
  try { process.umask(0o077); } catch (e) { /* ignore */ } // UDS socket 权限 = 0777 & ~umask → 0700
  mkdirSync(PATHS.dir, { recursive: true });
  try { chmodSync(PATHS.dir, 0o700); } catch (e) { /* ignore */ } // 显式收紧（已存在目录也覆盖）
}

// 返回 true=我们获得锁；false=已有存活 owner（本进程应作为 duplicate 退出）。
function acquireSingletonLock() {
  try {
    const fd = openSync(PATHS.lock, 'wx');
    try { writeSync(fd, String(process.pid)); } finally { closeSync(fd); }
    return true;
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
    let oldPid = 0;
    try { oldPid = Number(String(readFileSync(PATHS.lock, 'utf8')).trim()); } catch (q) { /* unreadable */ }
    if (pidAlive(oldPid)) return false; // owner 存活：duplicate，安静退出
    // owner 不存活：stale lock——在自己 namespace 内清理后重试一次
    dbg(`stale lock (pid ${oldPid || 'unknown'} not alive); reclaiming`);
    try { unlinkSync(PATHS.lock); } catch (q) { /* ignore */ }
    const fd = openSync(PATHS.lock, 'wx');
    try { writeSync(fd, String(process.pid)); } finally { closeSync(fd); }
    return true;
  }
}

// ---------- socket 健康 ping（startup 判定 stale socket 用）----------
function pingSocket(sockPath, timeoutMs = 500) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (ok) => { if (!settled) { settled = true; resolve(ok); } };
    let sock;
    try { sock = connect(sockPath); } catch (e) { return done(false); }
    const timer = setTimeout(() => { try { sock.destroy(); } catch (e) {} done(false); }, timeoutMs);
    sock.on('connect', () => {
      sock.write(JSON.stringify({ op: 'ping', op_id: 'boot-probe' }) + '\n');
    });
    sock.on('data', (d) => {
      if (String(d).includes('"ok":true')) { clearTimeout(timer); try { sock.destroy(); } catch (e) {} done(true); }
    });
    sock.on('error', () => { clearTimeout(timer); done(false); });
  });
}

// ---------- CDP core（lazy connect；epoch 计数）----------
const core = new CdpCore({
  udd: process.env.WZB_CDP_USER_DATA_DIR || `${process.env.HOME}/.config/google-chrome`,
  debug: dbg,
  onState: (s) => dbg(`state=${s}`),
});
let connecting = null;
async function ensureConnected() {
  if (core.wsOpen) return;
  if (!connecting) {
    connecting = core.connect().finally(() => { connecting = null; });
  }
  await connecting;
}

// ---------- op registry（同 op_id 防重复执行；仅内存，FIFO 上限）----------
const opRegistry = new Map(); // op_id → {status:'in_flight'} | {status:'done', response}
function registryRemember(opId) {
  opRegistry.set(opId, { status: 'in_flight' });
  if (opRegistry.size > OP_REGISTRY_LIMIT) {
    const oldest = opRegistry.keys().next().value;
    opRegistry.delete(oldest);
  }
}
function registryComplete(opId, response) {
  opRegistry.set(opId, { status: 'done', response });
  if (opRegistry.size > OP_REGISTRY_LIMIT) {
    const oldest = opRegistry.keys().next().value;
    opRegistry.delete(oldest);
  }
}

// ---------- 串行 browser-operation queue ----------
let queueTail = Promise.resolve();
function enqueueBrowserOp(task) {
  const run = queueTail.then(task, task); // 前序失败不阻塞后续
  queueTail = run.then(() => {}, () => {});
  return run;
}

// ---------- op 实现（browser op 全部经 ensureConnected + queue 串行）----------
async function opInit(opId) {
  return enqueueBrowserOp(async () => {
    await ensureConnected();
    const v = await core.version();
    return { op_id: opId, ok: true, product: v.product, protocolVersion: v.protocolVersion, ws_epoch: core.epoch };
  });
}
async function opStatus(opId) {
  return { op_id: opId, ok: true, ...core.connectionStatus(), pid: process.pid };
}
async function opPing(opId) {
  return { op_id: opId, ok: true, pong: true, pid: process.pid };
}
async function opList(opId) {
  return enqueueBrowserOp(async () => {
    await ensureConnected();
    const pages = await core.pages();
    return { op_id: opId, ok: true, pages: pages.map(p => ({ title: p.title, url: p.url })), ws_epoch: core.epoch };
  });
}
async function opOpen(opId, url) {
  return enqueueBrowserOp(async () => {
    await ensureConnected();
    const r = await core.open(url);
    return { op_id: opId, ok: true, targetId: r.targetId, ws_epoch: core.epoch };
  });
}
async function opEvaluate(opId, filter, js) {
  return enqueueBrowserOp(async () => {
    await ensureConnected();
    const r = await core.evaluate(filter, js);
    return { op_id: opId, ok: true, url: r.url, value: r.value, ws_epoch: core.epoch };
  });
}

async function dispatch(req) {
  const opId = req.op_id;
  if (opId === undefined || opId === null || typeof opId !== 'number' && typeof opId !== 'string') {
    return fail(opId, 'protocol_error', 'request missing op_id');
  }
  const key = String(opId);
  // 同 op_id 重复请求：in_flight → 明确拒绝且不执行；done → 返回缓存结果（§9.2：缓存用于
  // 查询，绝不重执行）。
  const prior = opRegistry.get(key);
  if (prior) {
    if (prior.status === 'in_flight') {
      return fail(opId, 'transport_failure', `duplicate op_id ${key}: operation already in flight; no re-execution`);
    }
    return { ...prior.response, _cached: true };
  }
  registryRemember(key);
  let response;
  try {
    switch (req.op) {
      case 'ping':        response = await opPing(opId); break;
      case 'status':      response = await opStatus(opId); break;
      case 'init':        response = await opInit(opId); break;
      case 'list_pages':  response = await opList(opId); break;
      case 'open_page':   response = await opOpen(opId, req.url); break;
      case 'evaluate':    response = await opEvaluate(opId, req.filter, req.js); break;
      case 'shutdown':
        response = { op_id: opId, ok: true, shutting_down: true };
        registryComplete(key, response);
        setImmediate(() => gracefulShutdown(0));
        return response;
      default:
        response = fail(opId, 'protocol_error', `unknown op: ${req.op}`);
    }
  } catch (e) {
    const category = e instanceof CdpError ? e.category : 'transport_failure';
    response = fail(opId, category, String(e.message || e).slice(0, 400));
  }
  registryComplete(key, response);
  return response;
}

// ---------- UDS server ----------
const server = createServer((sock) => {
  const rl = createInterface({ input: sock, crlfDelay: Infinity });
  rl.on('line', (line) => {
    if (line.trim() === '') return;
    let req;
    try { req = JSON.parse(line); } catch (e) {
      safeWrite(sock, JSON.stringify(fail(null, 'protocol_error', 'unparsable request line')) + '\n');
      return;
    }
    dispatch(req)
      .then((resp) => safeWrite(sock, JSON.stringify(resp) + '\n'))
      .catch((e) => safeWrite(sock, JSON.stringify(fail(req.op_id, 'transport_failure', String(e && e.message || e))) + '\n'));
  });
  sock.on('error', () => { /* client 断开；in-flight op 继续跑完并缓存（§9.2） */ });
});

function safeWrite(sock, s) { try { sock.write(s); } catch (e) { /* client gone */ } }

// ---------- 生命周期 ----------
let stopped = false;
function gracefulShutdown(code) {
  if (stopped) return;
  stopped = true;
  try { core.close(); } catch (e) { /* ignore */ }
  try { server.close(); } catch (e) { /* ignore */ }
  try { unlinkSync(PATHS.sock); } catch (e) { /* ignore */ }
  try { unlinkSync(PATHS.lock); } catch (e) { /* ignore */ }
  try { unlinkSync(PATHS.pid); } catch (e) { /* ignore */ }
  dbg(`broker exited (code ${code})`);
  process.exit(code);
}
process.on('SIGTERM', () => gracefulShutdown(0));
process.on('SIGINT', () => gracefulShutdown(0));

// ---------- main ----------
async function main() {
  prepareRuntimeDir();
  if (!acquireSingletonLock()) {
    dbg('duplicate broker: live owner holds the lock; exiting');
    process.exit(0);
  }
  // stale socket：仅在自己持有锁且 ping 证明无健康 owner 时清理（自己 namespace 内）
  if (existsSync(PATHS.sock)) {
    const healthy = await pingSocket(PATHS.sock);
    if (healthy) {
      dbg('socket answered ping but lock was free; treating as external healthy broker; exiting');
      try { unlinkSync(PATHS.lock); } catch (e) { /* ignore */ }
      process.exit(0);
    }
    dbg('removing stale socket (lock held, no healthy owner)');
    try { unlinkSync(PATHS.sock); } catch (e) { /* ignore */ }
  }
  const fd = openSync(PATHS.pid, 'w');
  try { writeSync(fd, String(process.pid)); } finally { closeSync(fd); }

  await new Promise((res, rej) => {
    server.once('error', rej);
    server.listen(PATHS.sock, res);
  });
  dbg(`broker listening (pid ${process.pid}, sock ${PATHS.sock}; browser WS lazy-on-first-op, no idle timeout)`);
  // 保持进程存活：UDS server + 后续 browser WS 事件循环
  setInterval(() => {}, 1 << 30);
}

main().catch((e) => {
  process.stderr.write(`wzb-broker: fatal: ${e && e.message}\n`);
  try { unlinkSync(PATHS.lock); } catch (q) { /* ignore */ }
  process.exit(1);
});
