#!/usr/bin/env node
// webgpt-zcode-bridge — Linux broker client（Batch 5C 默认 transport IPC 进程）。
//
// 职责：与 cdp-client.mjs 相同的 stdio line-JSON 协议（transport.sh 无感），但对端不是
// 直连 Chrome 的 one-shot helper，而是持久 cdp-broker（UDS）。
//
// 协议适配（transport 协议 ↔ broker 契约协议）：
//   - transport 请求以 `id` 关联响应；broker 契约要求请求携带全局唯一 `op_id`。
//   - 本适配器为每个转发请求生成全局唯一 op_id（boot nonce + 递增序号，跨 client 不碰撞），
//     并维护 op_id → 请求 id 映射；broker 响应改写回 `id` 字段后回传 stdout。
//   - 除 id/op_id 外字段原样透传；transport 的串行请求习惯下映射极小。
//
// broker 生命周期（spec §15）：启动时 ping 既有 broker；健康 → 直接复用；不可达 →
// 以 detached 子进程启动 cdp-broker.mjs（其单例锁保证不会出现 duplicate），随后有界
// 等待 IPC ready（WZB_CDP_BROKER_START_TIMEOUT，默认 15s）。超时 → 进程退出
// （transport 侧表现为 pipe closed / timeout 的 transport_failure）。
// broker 的 stale socket/lock 清理完全由 broker 自身完成（client 不触碰）。
//
// at-most-once（§9.2）：本适配器对任何失败（含自身 IPC 断开）都不重发请求——
// 重试只可能由上层发起新的 operation（新 op_id），那属于新的 CLI 语义动作。
//
// Allow 提示：转发中的 request 超过阈值后，经独立 UDS control-plane status 证明 broker
// 正处于 browser connect attempt 才输出；ready 的慢页面操作不得误报。
//
// stdin EOF / SIGTERM → 关闭 UDS 连接退出。绝不向 broker 发送 shutdown（共享进程，
// 显式 shutdown 只属于本地维护操作）。
//
// 环境变量：WZB_CDP_BROKER_SOCK / WZB_CDP_BROKER_START_TIMEOUT（默认 15）/
// WZB_CDP_USER_DATA_DIR / WZB_CDP_CONNECT_TIMEOUT / WZB_CDP_CMD_TIMEOUT /
// WZB_CDP_EVAL_TIMEOUT / WZB_CDP_DEBUG（透传给 broker 及其提示行为）

import { connect } from 'node:net';
import { createInterface } from 'node:readline';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveBrokerPaths } from './cdp-core.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const BROKER = join(HERE, 'cdp-broker.mjs');
const PATHS = resolveBrokerPaths();
const START_TIMEOUT_MS = (Number(process.env.WZB_CDP_BROKER_START_TIMEOUT) || 15) * 1000;
const hintDelayValue = Number(process.env.WZB_CDP_ALLOW_HINT_DELAY_MS);
const ALLOW_HINT_DELAY_MS = Number.isFinite(hintDelayValue) && hintDelayValue >= 0 ? hintDelayValue : 3000;

function out(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }
function errLine(s) { process.stderr.write(s + '\n'); }

function pingBroker(sockPath, timeoutMs = 700) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (ok) => { if (!settled) { settled = true; resolve(ok); } };
    let sock;
    try { sock = connect(sockPath); } catch (e) { return done(false); }
    const timer = setTimeout(() => { try { sock.destroy(); } catch (e) {} done(false); }, timeoutMs);
    sock.on('connect', () => sock.write(JSON.stringify({ op: 'ping', op_id: `probe-${process.pid}-${Date.now()}` }) + '\n'));
    sock.on('data', (d) => { if (String(d).includes('"ok":true')) { clearTimeout(timer); try { sock.destroy(); } catch (e) {} done(true); } });
    sock.on('error', () => { clearTimeout(timer); done(false); });
  });
}

// 独立 control-plane 连接：status 在 broker 内不进 browser queue，也不会触发 browser connect。
function readBrokerStatus(sockPath, timeoutMs = 700) {
  return new Promise((resolve) => {
    let settled = false, buf = '';
    const done = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { sock.destroy(); } catch (e) { /* ignore */ }
      resolve(value);
    };
    let sock;
    try { sock = connect(sockPath); } catch (e) { resolve(null); return; }
    const timer = setTimeout(() => done(null), timeoutMs);
    sock.on('connect', () => sock.write(JSON.stringify({
      op: 'status', op_id: `hint-status-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    }) + '\n'));
    sock.on('data', (d) => {
      buf += String(d);
      const nl = buf.indexOf('\n');
      if (nl < 0) return;
      try { done(JSON.parse(buf.slice(0, nl))); } catch (e) { done(null); }
    });
    sock.on('error', () => done(null));
    sock.on('close', () => done(null));
  });
}

async function ensureBroker() {
  if (await pingBroker(PATHS.sock)) return true;
  // 以 detached 方式启动 broker（survive CLI 退出）；单例锁由 broker 自持。
  // 相关 env 显式透传（含测试用的 sock/udd 覆盖与超时）。
  const child = spawn(process.execPath, [BROKER], {
    detached: true,
    stdio: 'ignore',
    env: {
      ...process.env,
      WZB_CDP_BROKER_SOCK: process.env.WZB_CDP_BROKER_SOCK || PATHS.sock,
    },
  });
  child.unref();
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, 250));
    if (await pingBroker(PATHS.sock)) return true;
  }
  return false;
}

async function main() {
  if (!(await ensureBroker())) {
    errLine('wzb-broker-client: broker did not become ready in time; check broker state');
    process.exit(1);
  }
  const sock = connect(PATHS.sock);
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('broker UDS connect timeout')), 5000);
    sock.on('connect', () => { clearTimeout(t); res(); });
    sock.on('error', (e) => { clearTimeout(t); rej(e); });
  });

  // Allow 提示：每个在途请求到阈值时只检查一次；整个 client 最多打印一次。只有 status 同时
  // 证明 connecting + 未连接 + attempt id 非空，才可能是浏览器 Allow 在等待。
  let hinted = false;
  const hintTimers = new Map();
  const armHint = (opId) => {
    if (hinted || opId === null) return;
    const timer = setTimeout(async () => {
      hintTimers.delete(opId);
      const status = await readBrokerStatus(PATHS.sock);
      if (hinted || !opIdToLocal.has(opId)) return; // 原请求已完成时不得迟到输出提示。
      if (status && status.ok === true && status.state === 'connecting'
          && status.browser_connected === false && status.current_connect_attempt_id !== null
          && status.current_connect_attempt_id !== undefined) {
        hinted = true;
        errLine('Chrome may be waiting for Remote Debugging Allow — check the browser window');
      }
    }, ALLOW_HINT_DELAY_MS);
    hintTimers.set(opId, timer);
  };
  const clearHint = (opId) => {
    const timer = hintTimers.get(opId);
    if (timer) clearTimeout(timer);
    hintTimers.delete(opId);
  };
  const clearAllHints = () => {
    for (const timer of hintTimers.values()) clearTimeout(timer);
    hintTimers.clear();
  };

  // op_id 适配：全局唯一（boot nonce + 序号），映射回 transport 的请求 id
  const NONCE = Math.random().toString(16).slice(2, 8);
  let seq = 0;
  const opIdToLocal = new Map();
  // op 名映射：transport 内部名（cdp-client 遗产）→ broker 契约名（spec §7）
  const OP_ALIAS = { list: 'list_pages', open: 'open_page', eval: 'evaluate' };
  const rewriteOutgoing = (line) => {
    let req;
    try { req = JSON.parse(line); } catch (e) { return null; }
    const opId = `c${process.pid}-${NONCE}-${++seq}`;
    const { id, op, ...rest } = req;
    opIdToLocal.set(opId, id);
    return { opId, line: JSON.stringify({ ...rest, op: OP_ALIAS[op] || op, op_id: opId }) };
  };
  const rewriteIncoming = (line) => {
    let resp;
    try { resp = JSON.parse(line); } catch (e) { return null; }
    const { op_id, _cached, ...rest } = resp;
    const localId = op_id !== undefined ? opIdToLocal.get(op_id) : undefined;
    if (localId !== undefined) {
      clearHint(op_id);
      opIdToLocal.delete(op_id);
    }
    return JSON.stringify({ ...rest, id: localId !== undefined ? localId : -1 });
  };

  // 完整行缓冲重组：响应可能跨越多个 data chunk（conv raw ~1.5MB），
  // 只有以 '\n' 结尾的完整行才解析/改写，残余字节留在缓冲区等待下一 chunk。
  let sockBuf = '';
  sock.on('data', (d) => {
    sockBuf += String(d);
    let nl;
    while ((nl = sockBuf.indexOf('\n')) >= 0) {
      const line = sockBuf.slice(0, nl);
      sockBuf = sockBuf.slice(nl + 1);
      if (line.trim() === '') continue;
      const rewritten = rewriteIncoming(line);
      if (rewritten) process.stdout.write(rewritten + '\n');
    }
  });
  sock.on('close', () => { clearAllHints(); process.exit(0); });
  sock.on('error', () => { clearAllHints(); process.exit(0); });

  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('line', (line) => {
    if (line.trim() === '') return;
    const rewritten = rewriteOutgoing(line);
    if (!rewritten) return;
    armHint(rewritten.opId);
    try { sock.write(rewritten.line + '\n'); } catch (e) { /* broker gone */ }
  });
  rl.on('close', () => { clearAllHints(); try { sock.destroy(); } catch (e) {} process.exit(0); });
  process.on('SIGTERM', () => { clearAllHints(); try { sock.destroy(); } catch (e) {} process.exit(0); });
}

main().catch((e) => {
  errLine(`wzb-broker-client: ${e && e.message}`);
  process.exit(1);
});
