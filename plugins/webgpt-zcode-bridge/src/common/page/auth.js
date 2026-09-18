// webgpt-zcode-bridge common page layer — auth + backend access.
// 页面约定（spec/page-contract.md §1、§4、§5）：
//   accessToken 只在本 evaluation 作用域内取得并使用，绝不作为返回值离开页面；
//   transport 只拿到业务结果或认证布尔/错误类别。
// 本文件只定义函数，无顶层副作用；除页面环境外也可在 JXA 中安全加载。
// auth/backend endpoint 集中于此（spec/page-contract.md §5、§16 私有接口风险集中管理）。

var WZB_ORIGIN = 'https://chatgpt.com';

function __wzbErrObj(category, reason) {
  return { ok: false, category: category, reason: reason || category };
}

// 同步 XHR（页面主线程；legacy 已实机验证该通道）
function __wzbXhr(method, url, bearer) {
  var r = new XMLHttpRequest();
  r.open(method, url, false);
  if (bearer) r.setRequestHeader('Authorization', bearer);
  r.send();
  return { status: r.status, text: r.responseText };
}

// GET /api/auth/session 并在本次 evaluation 内继续访问 backend。
// 失败：{ok:false, category:'not_logged_in'}；成功：{ok:true, status, text}（backend 响应本体）。
function __wzbAuthGet(path) {
  var s = __wzbXhr('GET', WZB_ORIGIN + '/api/auth/session', null);
  if (s.status !== 200) return __wzbErrObj('not_logged_in', 'auth session HTTP ' + s.status);
  var e = {};
  try { e = JSON.parse(s.text || '{}'); } catch (q) { return __wzbErrObj('not_logged_in', 'auth session unparsable'); }
  if (!e.accessToken) return __wzbErrObj('not_logged_in', 'no accessToken in session');
  var r = __wzbXhr('GET', WZB_ORIGIN + path, 'Bearer ' + e.accessToken);
  return { ok: true, status: r.status, text: r.text };
}

// backend 非 2xx → {ok:false, category:'backend_http_error'}（spec §5）
function __wzbBackendGet(path) {
  var r = __wzbAuthGet(path);
  if (!r.ok) return r;
  if (r.status < 200 || r.status >= 300) return __wzbErrObj('backend_http_error', 'HTTP ' + r.status + ' for ' + path);
  return r;
}
