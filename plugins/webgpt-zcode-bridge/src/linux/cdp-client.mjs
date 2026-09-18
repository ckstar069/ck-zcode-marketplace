#!/usr/bin/env node
// webgpt-zcode-bridge — Linux CDP helper（one-shot；5C 起 CDP 机制抽取至 cdp-core.mjs 共享，
// 与持久 cdp-broker.mjs 同源，行为与 Batch 3/4/5 已验收版本一致）。
//
// lifecycle：one CLI invocation = one helper = one browser WebSocket（legacy direct 模式；
// 默认 transport 路径已切换到 broker-client + cdp-broker，本文件保留为
// WZB_CDP_DIRECT=1 的直连调试/回退路径，并被 at-most-once / target-binding 合成套件直接驱动）。
//
// stdin/stdout 为严格机器协议（每请求一行 JSON，每响应一行 JSON）；CDP event（无 id）一律忽略；
// stdin EOF → 干净断开退出；绝不调用 Browser.close / Target.closeTarget。
//
// 环境变量：WZB_CDP_USER_DATA_DIR / WZB_CDP_CONNECT_TIMEOUT / WZB_CDP_CMD_TIMEOUT /
// WZB_CDP_EVAL_TIMEOUT / WZB_CDP_DEBUG=1

import { createInterface } from 'node:readline';
import { CdpCore, CdpError } from './cdp-core.mjs';

const DEBUG = process.env.WZB_CDP_DEBUG === '1';
const dbg = (m) => { if (DEBUG) process.stderr.write(`wzb-cdp: ${m}\n`); };

function failResp(id, category, reason) { return { id, ok: false, category, reason }; }

const core = new CdpCore({
  udd: process.env.WZB_CDP_USER_DATA_DIR || `${process.env.HOME}/.config/google-chrome`,
  debug: dbg,
});

async function opInit(id) {
  await core.connect();
  const v = await core.version();
  return { id, ok: true, product: v.product, protocolVersion: v.protocolVersion };
}
async function opList(id) {
  const pages = await core.pages();
  return { id, ok: true, pages: pages.map(p => ({ title: p.title, url: p.url })) };
}
async function opOpen(id, url) {
  const r = await core.open(url);
  return { id, ok: true, targetId: r.targetId };
}
async function opEval(id, filter, js) {
  const r = await core.evaluate(filter, js);
  return { id, ok: true, url: r.url, value: r.value };
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
let shuttingDown = false;

function respond(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

rl.on('line', async (line) => {
  if (shuttingDown || line.trim() === '') return;
  let req;
  try { req = JSON.parse(line); } catch (e) {
    respond(failResp(-1, 'transport_failure', `unparsable request line: ${String(e.message).slice(0, 120)}`));
    return;
  }
  const id = req.id;
  try {
    switch (req.op) {
      case 'init':      respond(await opInit(id)); break;
      case 'list':      respond(await opList(id)); break;
      case 'open':      respond(await opOpen(id, req.url)); break;
      case 'eval':      respond(await opEval(id, req.filter, req.js)); break;
      case 'shutdown':  respond({ id, ok: true }); shutdown(0); break;
      default:          respond(failResp(id, 'transport_failure', `unknown op: ${req.op}`));
    }
  } catch (e) {
    const category = e instanceof CdpError ? e.category : 'transport_failure';
    respond(failResp(id, category, String(e.message || e).slice(0, 400)));
  }
});

rl.on('close', () => { if (!shuttingDown) shutdown(0); }); // stdin EOF（CLI 结束）→ 干净退出

function shutdown(code) {
  shuttingDown = true;
  core.close();
  dbg('helper exited cleanly');
  process.exit(code);
}

dbg(`helper started (pid ${process.pid}, connect timeout ${core.connectTimeoutMs / 1000}s)`);
