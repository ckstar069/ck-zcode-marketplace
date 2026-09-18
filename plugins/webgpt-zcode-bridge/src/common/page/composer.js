// webgpt-zcode-bridge common page layer — composer / send-button / click（页面 DOM，仅页面环境调用）。
// 依据 spec/page-contract.md §10（readiness）、§11（读取）、§13（写入+readback）、§14（send-ready 轮询）、
// §15（generation 指标不固化）、§16（清空+复核）、§17（click 前提与唯一 selector）。
//
// 安全结构约定：
//   - webgptPageSendClick 是唯一 click 入口，仅由 CLI 的 --send 分支组合执行；
//     默认 dry-run 路径的 evaluation bundle 中不包含对本函数的调用。
//   - 所有函数返回 JSON 可序列化对象，由统一 wrapper JSON.stringify 后交 transport；
//     任何返回值都不含 token/cookie。

function __wzbComposerEl() {
  return document.querySelector('#prompt-textarea');
}

// ---------- canonical plain-text reader（spec/page-contract.md §11.1） ----------
// 不使用 root textContent / root innerText；不 trim、不折叠空白、不 Unicode normalize。
// top-level childNodes 按 DOM 顺序逐个序列化，segment 之间插入且只插入一个 \n。

function __wzbNodeHasClass(node, cls) {
  var c = (node.getAttribute && node.getAttribute('class')) || node.className || '';
  var parts = String(c).split(/\s+/);
  for (var i = 0; i < parts.length; i++) if (parts[i] === cls) return true;
  return false;
}

// 单节点序列化：text node 原文；普通 <br> → \n；br.ProseMirror-trailingBreak → ''（结构占位）；
// 其它 element 递归 descendants；未知节点类型不贡献文本。deterministic，无启发式修复。
function __wzbSerializeNode(node) {
  if (!node) return '';
  if (node.nodeType === 3) return node.nodeValue || '';
  if (node.nodeType === 1 && node.nodeName === 'BR') {
    return __wzbNodeHasClass(node, 'ProseMirror-trailingBreak') ? '' : '\n';
  }
  if (node.nodeType === 1) {
    var cs = node.childNodes || [];
    var out = '';
    for (var i = 0; i < cs.length; i++) out += __wzbSerializeNode(cs[i]);
    return out;
  }
  return '';
}

// contenteditable 根读取：top-level segments 用单个 \n join；空 block 自然表示空行。
function __wzbComposerReadEditable(root) {
  var cs = root.childNodes || [];
  var out = [];
  for (var i = 0; i < cs.length; i++) out.push(__wzbSerializeNode(cs[i]));
  return out.join('\n');
}

// 完整内容读取：contenteditable 走 canonical reader，textarea fallback 用 value；不 trim。
function __wzbComposerRead(el) {
  return el.isContentEditable ? __wzbComposerReadEditable(el) : (el.value || '');
}

function __wzbComposerInput(el, text) {
  var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
  setter.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

// 已打开会话页的 readiness（GATE3-FIX1：cheap non-authorizing hint）。
// 只检查：URL /c/<id> 精确等于 expected（__wzbPathConvId 纯 helper）+ #prompt-textarea 存在 +
// /api/auth/session 200 且有 accessToken + DOM [data-message-id] count > 0。
// 不调用 webgptConversationIdentity / __wzbBackendGet / webgptActiveBranch —— 每个 poll 最多
// 一次 auth session 请求、零次完整 conversation backend fetch；identity_candidate 不验证 branch
// membership，不构成 mutation 授权：mutation 仍由 §22 atomic gate 在 mutation evaluation 内完成。
// 真正空 conversation 的 DOM 为空 → identity_candidate=false（第一版 fail-closed 不变）。
// auth 失败只报 auth=false，不伪装成 identity 错误。
function webgptPageReadiness(expectedConversationId) {
  var el = __wzbComposerEl();
  var auth = false;
  try {
    var s = __wzbXhr('GET', WZB_ORIGIN + '/api/auth/session', null);
    if (s.status === 200) {
      var e = JSON.parse(s.text || '{}');
      auth = !!e.accessToken;
    }
  } catch (q) { /* auth 探测失败按未登录处理 */ }
  var urlOk = !!(auth && expectedConversationId &&
    __wzbPathConvId(document.location.pathname) === expectedConversationId);
  var domCount = document.querySelectorAll('[data-message-id]').length;
  var candidate = !!(urlOk && domCount > 0);
  return {
    ok: true,
    ready: !!(el && auth && candidate),
    auth: auth,
    identity_candidate: candidate,
    identity_category: (auth && !candidate) ? 'conversation_identity_unverified' : null
  };
}

// 写入前置 + 写入 + 精确 readback（spec §11/§13）。
// §22：任何 DOM mutation 前先在同一 evaluation 内原子完成 conversation identity gate；
// identity 失败 → 直接返回其 envelope（composer 不被触碰）。
// composer 非空 → composer_not_empty，不追加、不覆盖、不清空。
// 不检测“生成中”：当前没有经三平台动态验证的指标（spec §15），由 send-button ready 兜底。
function webgptPageSendPrecheck(expectedConversationId, message) {
  var idv = webgptConversationIdentity(expectedConversationId);
  if (!idv.ok) return idv;
  var el = __wzbComposerEl();
  if (!el) return __wzbErrObj('composer_unavailable', '#prompt-textarea not found');
  var cur = __wzbComposerRead(el);
  if (cur !== '') {
    return __wzbErrObj('composer_not_empty', 'composer has existing content (length ' + cur.length + '); leaving it untouched');
  }
  el.focus();
  if (el.isContentEditable) {
    document.execCommand('insertText', false, message);
  } else {
    __wzbComposerInput(el, message);
  }
  var actual = __wzbComposerRead(el);
  if (actual !== message) {
    return __wzbErrObj('composer_write_mismatch', 'readback length ' + actual.length + ' != expected ' + message.length + '; composer left for manual inspection');
  }
  return { ok: true, written_length: actual.length };
}

// send-ready 探测（独立 evaluation；spec §13：不得假设同一同步 evaluate 内 React 已更新按钮）。
// 返回 ready 状态而非错误，供 CLI 轮询；composer 内容变化立即失败。
function webgptPageSendReady(expectedMessage) {
  var el = __wzbComposerEl();
  if (!el) return __wzbErrObj('composer_unavailable', '#prompt-textarea not found');
  var cur = __wzbComposerRead(el);
  if (cur !== expectedMessage) {
    return __wzbErrObj('composer_write_mismatch', 'composer content changed while waiting for send button');
  }
  var b = document.querySelector('button[data-testid="send-button"]');
  if (!b) return { ok: true, ready: false, button_exists: false, button_disabled: null };
  var dis = b.disabled === true || b.getAttribute('aria-disabled') === 'true';
  return { ok: true, ready: !dis, button_exists: true, button_disabled: dis };
}

// 只读 composer state（spec §16.2 轮询探针）：canonical text + 存在性，无任何修改。
// composer 缺失时 text 为 null（不得当作空串确认）。
function webgptPageComposerState() {
  var el = __wzbComposerEl();
  if (!el) return { ok: true, exists: false, text: null };
  return { ok: true, exists: true, text: __wzbComposerRead(el) };
}

// Pre-click cleanup / dry-run clear 唯一 mutation 入口（spec §16.1/§16.2/§21）：
// §22：clear mutation 前先原子 identity gate；route/DOM 已切换 → conversation_identity_unverified
// 且 NO CLEAR（正确 fail-safe，不得为清理工具文本放宽 identity）。
// 仅当 canonical 内容仍精确等于 expected 时执行**一次** clear mutation（selectAll+delete / value setter）；
// 返回不包含清空结果判定——空态确认由 orchestration 用只读 State 轮询异步完成（§16.2）。
// 内容已变化（并发用户输入/页面改动）→ untouched，不做任何修改；
// composer 不存在 → skipped，不做破坏性动作。不使用 trim、前缀匹配或 substring 判断。
function webgptPageComposerClearIfExact(expectedConversationId, expectedMessage) {
  var idv = webgptConversationIdentity(expectedConversationId);
  if (!idv.ok) return idv;
  var el = __wzbComposerEl();
  if (!el) return { ok: true, action: 'skipped', reason: 'composer unavailable; no destructive action' };
  var cur = __wzbComposerRead(el);
  if (cur !== expectedMessage) {
    return { ok: true, action: 'untouched', reason: 'composer content changed; left untouched; inspect manually' };
  }
  el.focus();
  if (el.isContentEditable) {
    document.execCommand('selectAll');
    document.execCommand('delete');
  } else {
    __wzbComposerInput(el, '');
  }
  return { ok: true, action: 'cleared' };
}

// 真实发送唯一 click 入口（spec §17）。§22：click 前先原子 identity gate（同一 evaluation），
// identity 失败 → 不 click。随后在页面内原子复核：
// composer 精确等于 message、按钮存在且可用；唯一 selector button[data-testid="send-button"]。
function webgptPageSendClick(expectedConversationId, message) {
  var idv = webgptConversationIdentity(expectedConversationId);
  if (!idv.ok) return idv;
  var el = __wzbComposerEl();
  if (!el) return __wzbErrObj('composer_unavailable', '#prompt-textarea not found');
  var cur = __wzbComposerRead(el);
  if (cur !== message) {
    return __wzbErrObj('composer_write_mismatch', 'composer content no longer equals message immediately before click; click refused');
  }
  var b = document.querySelector('button[data-testid="send-button"]');
  if (!b) return __wzbErrObj('send_button_unavailable', 'send button missing immediately before click');
  if (b.disabled === true || b.getAttribute('aria-disabled') === 'true') {
    return __wzbErrObj('send_button_disabled', 'send button disabled immediately before click');
  }
  b.click();
  return { ok: true, clicked: true };
}
