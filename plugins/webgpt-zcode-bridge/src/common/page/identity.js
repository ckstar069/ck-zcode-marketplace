// webgpt-zcode-bridge common page layer — conversation identity gate（Batch 4C-GATE3）。
// 依据 spec/page-contract.md §22（mutation identity invariant，第一版冻结设计）：
//   PASS 当且仅当
//     1. location.pathname 解析出的 /c/<id> 与 expected conversation id 精确相等（大小写敏感）；
//     2. DOM [data-message-id] 集合非空；
//     3. 每个 DOM data-message-id ∈ expected conversation 的 backend active branch node ids。
//   明确不要求：DOM == full branch（虚拟化允许）；DOM 为连续分支切片；DOM last == current_node
//   （tail_is_current 仅 diagnostic，不参与判定）；visibilityState == visible（hidden page 允许）。
//   证据基础（2026-09-13/14 Windows 动态验证）：data-message-id 即 mapping node id，且该 backend
//   中 node.id === message.id（598/598）；DOM 常为分支子集（5/590）；hidden page 可收缩至 1 条且
//   未必保留 tail；SPA 过渡期 URL 已变而旧 DOM 未清；composer 存在不是会话身份。
// 失败 → {ok:false, category:'conversation_identity_unverified', reason}（稳定类别）；
//   reason 不输出 message body，也不输出完整 DOM message id 列表。
// backend/auth/transcript 自身错误按原类别透传（__wzbBackendGet / webgptActiveBranch envelope）。
// 依赖 auth.js、transcript.js；不复制 backend endpoint 与 active-branch 算法。
// 除页面环境外也可在 JXA/Node 测试环境加载（webgptIdentityVerdict 为纯函数，无页面 API）。

// pathname → conversation id：只看 path 段（query/fragment 中的 /c/ 永不生效），
// 支持项目形态 /g/g-p-<pid>/c/<id>；与 transport 侧 wzb_conv_id_from_url /
// ConvertFrom-WzbConvId 同为“第一个 /c/ 段”语义（跨平台一致，含边界行为）。
function __wzbPathConvId(pathname) {
  var segs = String(pathname || '').split('/');
  for (var i = 0; i < (segs.length - 1); i++) {
    if (segs[i] === 'c' && segs[i + 1] !== '' && /^[A-Za-z0-9-]+$/.test(segs[i + 1])) {
      return segs[i + 1];
    }
  }
  return '';
}

// 纯判定核心（fixture 直测；风格同 webgptVerifyCheck）。
// 输入：location pathname、expected conversation id、backend active-branch node ids、
// DOM 顺序收集的 data-message-id 值。成功 {ok:true, verified:true, dom_count, branch_count}。
function webgptIdentityVerdict(pathname, expectedConversationId, branchNodeIds, domIds) {
  if (!expectedConversationId) {
    return __wzbErrObj('conversation_identity_unverified', 'expected conversation id is empty');
  }
  var pageId = __wzbPathConvId(pathname);
  if (pageId !== expectedConversationId) {
    return __wzbErrObj('conversation_identity_unverified',
      pageId ? 'page URL resolves to a different conversation' : 'page URL does not resolve to /c/<id>');
  }
  var dom = domIds || [];
  if (dom.length === 0) {
    return __wzbErrObj('conversation_identity_unverified', 'DOM has no [data-message-id] elements');
  }
  var onBranch = {};
  var branch = branchNodeIds || [];
  for (var i = 0; i < branch.length; i++) onBranch[branch[i]] = 1;
  for (var j = 0; j < dom.length; j++) {
    if (!onBranch[dom[j]]) {
      return __wzbErrObj('conversation_identity_unverified',
        'DOM message id at index ' + j + ' is not on the expected conversation active branch');
    }
  }
  return { ok: true, verified: true, dom_count: dom.length, branch_count: branch.length };
}

// 完整 identity gate：URL 短路 → fetch expected backend conversation → active branch →
// DOM 收集 → webgptIdentityVerdict。成功附带 tail_is_current diagnostic（不参与 verified）。
// 只返回低敏感摘要；任何 token/body/完整 id 列表都不离开页面 evaluation。
function webgptConversationIdentity(expectedConversationId) {
  if (!expectedConversationId) {
    return __wzbErrObj('conversation_identity_unverified', 'expected conversation id is empty');
  }
  var pageId = __wzbPathConvId(document.location.pathname);
  if (pageId !== expectedConversationId) {
    return __wzbErrObj('conversation_identity_unverified',
      pageId ? 'page URL resolves to a different conversation' : 'page URL does not resolve to /c/<id>');
  }
  var r = __wzbBackendGet('/backend-api/conversation/' + encodeURIComponent(expectedConversationId));
  if (!r.ok) return r;
  var d;
  try { d = JSON.parse(r.text); } catch (q) { return __wzbErrObj('backend_parse_error', 'conversation response unparsable'); }
  var b = webgptActiveBranch(d);
  if (!b.ok) return b;
  var els = document.querySelectorAll('[data-message-id]');
  var dom = [];
  for (var i = 0; i < els.length; i++) {
    var v = els[i].getAttribute('data-message-id');
    if (v) dom.push(v);
  }
  var verdict = webgptIdentityVerdict(document.location.pathname, expectedConversationId, b.node_ids, dom);
  if (!verdict.ok) return verdict;
  verdict.tail_is_current = dom.length > 0 && dom[dom.length - 1] === d.current_node;
  return verdict;
}
