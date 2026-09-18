// webgpt-zcode-bridge common page layer — 单 conversation 读取入口。
// 依据 spec/page-contract.md §7（conv raw 不投影）、§8（transcript）、§18（verify）。
// 依赖 auth.js、transcript.js、verify.js。

function __wzbFetchConv(id) {
  var r = __wzbBackendGet('/backend-api/conversation/' + encodeURIComponent(id));
  if (!r.ok) return r;
  return { ok: true, text: r.text };
}

// conv 子命令：raw passthrough（backend 响应文本原样返回，由 CLI 输出本体）。
function webgptPageConvRaw(id) {
  var r = __wzbFetchConv(id);
  if (!r.ok) return r;
  return { ok: true, raw: r.text };
}

// transcript 子命令：页面内完成 active-branch 线性化（复用纯函数算法）。
function webgptPageTranscript(id) {
  var r = __wzbFetchConv(id);
  if (!r.ok) return r;
  var d;
  try { d = JSON.parse(r.text); } catch (q) { return __wzbErrObj('backend_parse_error', 'conversation response unparsable'); }
  return webgptLinearize(d);
}

// verify：pre-click 快照（current_node + 全量 node id set + branch）。
function webgptPageVerifySnapshot(id) {
  var r = __wzbFetchConv(id);
  if (!r.ok) return r;
  var d;
  try { d = JSON.parse(r.text); } catch (q) { return __wzbErrObj('backend_parse_error', 'conversation response unparsable'); }
  return webgptVerifyState(d);
}

// verify：post-click 轮询检查。pre 为 webgptPageVerifySnapshot 的 {current_node,node_ids}；
// 页面内取 post 状态并跑 webgptVerifyCheck。
// 成功 envelope 统一携带 ok:true（CLI 在读取 .status 前先校验 .ok）；
// 纯函数 webgptVerifyCheck 的 contract 不变（status/candidate 原样透传）。
// message 为原始未转义文本（由 JSON 序列化安全传入，spec §12）。
function webgptPageVerifyCheck(id, pre, message) {
  var r = __wzbFetchConv(id);
  if (!r.ok) return r;
  var d;
  try { d = JSON.parse(r.text); } catch (q) { return __wzbErrObj('backend_parse_error', 'conversation response unparsable'); }
  var post = webgptVerifyState(d);
  if (!post.ok) return post;
  var check = webgptVerifyCheck(pre.current_node, pre.node_ids, post.branch, message);
  check.ok = true;
  return check;
}
