// webgpt-zcode-bridge common page layer — conversation list 读取与投影。
// 依据 spec/page-contract.md §6（list 投影）与 spec/cli-contract.md §5/§6（list/find 输出）。
// 依赖 auth.js。

// update_time → updated。有效数值转 UTC ISO 并截断；无法转换保留可打印原值/空串。
// list 输出用日期（10），find 输出用秒级时间戳（19）——与 legacy 兼容行为一致。
function __wzbTs(v, len) {
  var n = Number(v);
  return (isFinite(n) && n > 0) ? new Date(n * 1000).toISOString().slice(0, len) : String(v || '');
}

function __wzbListItems(d, len) {
  var items = Array.isArray(d.items) ? d.items : [];
  var out = [];
  for (var i = 0; i < items.length; i++) {
    var it = items[i];
    out.push({
      id: it.id,
      title: it.title,
      updated: __wzbTs(it.update_time, len),
      archived: it.is_archived === true,
      gizmo: it.gizmo_id || null
    });
  }
  return out;
}

// list 子命令入口（limit 已由 CLI 校验为 1..100 整数）。
function webgptPageList(limit) {
  var r = __wzbBackendGet('/backend-api/conversations?offset=0&limit=' + limit + '&order=updated');
  if (!r.ok) return r;
  var d;
  try { d = JSON.parse(r.text); } catch (q) { return __wzbErrObj('backend_parse_error', 'conversations response unparsable'); }
  return { ok: true, total: d.total, items: __wzbListItems(d, 10) };
}

// find 子命令的 backend 数据源：最近更新最多 100 条，updated 为秒级时间戳。
function webgptPageFindList() {
  var r = __wzbBackendGet('/backend-api/conversations?offset=0&limit=100&order=updated');
  if (!r.ok) return r;
  var d;
  try { d = JSON.parse(r.text); } catch (q) { return __wzbErrObj('backend_parse_error', 'conversations response unparsable'); }
  return { ok: true, items: __wzbListItems(d, 19) };
}
