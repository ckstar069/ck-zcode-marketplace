// webgpt-zcode-bridge common page layer — active-branch transcript（纯函数，无页面 API）。
// 依据 spec/page-contract.md §8 与 spec/cli-contract.md §8：
//   顺序严格由 current_node → parent → … → root 再 reverse 恢复；
//   禁止全树 DFS / mapping 插入顺序 / create_time 猜测；
//   parent 缺失 → transcript_broken_parent；cycle / >20000 hops → transcript_cycle；
//   所有 role 保留；content_type==text 仅取 string parts 按 \n join；
//   其它 content_type → [<type>]；缺失 → [unknown]；最终为空的消息跳过。
// 可在页面环境与 JXA 测试环境中运行（无顶层副作用）。

// 校验 + 回溯 active branch；成功返回 {ok:true,node_ids:[root…current]}，
// 失败返回 {ok:false,category,reason}。
function webgptActiveBranch(d) {
  if (!d || typeof d !== 'object') return __wzbErrObj('backend_parse_error', 'conversation not an object');
  if (!d.mapping || typeof d.mapping !== 'object') return __wzbErrObj('backend_parse_error', 'mapping missing');
  if (!d.current_node || typeof d.current_node !== 'string') return __wzbErrObj('backend_parse_error', 'current_node missing');
  var mapping = d.mapping;
  var order = [];
  var seen = {};
  var cur = d.current_node;
  var hops = 0;
  while (true) {
    var node = mapping[cur];
    if (!node || typeof node !== 'object') return __wzbErrObj('transcript_broken_parent', 'node not in mapping: ' + cur);
    if (seen[cur]) return __wzbErrObj('transcript_cycle', 'revisited node: ' + cur);
    seen[cur] = 1;
    order.push(cur);
    var p = node.parent;
    if (p === null || p === undefined) break;
    if (typeof p !== 'string') return __wzbErrObj('transcript_broken_parent', 'parent not a string at node: ' + cur);
    hops++;
    if (hops > 20000) return __wzbErrObj('transcript_cycle', 'exceeded 20000 parent hops');
    cur = p;
  }
  order.reverse();
  return { ok: true, node_ids: order };
}

// 消息文本提取（transcript 投影与 verify 分支提取共用同一语义）：
// text 类型仅取 string parts 按 \n join；其它类型 [type]；content 缺失 [unknown]。
function __wzbMessageText(m) {
  var c = m.content;
  if (c && typeof c === 'object' && c.content_type === 'text') {
    var parts = Array.isArray(c.parts) ? c.parts : [];
    var strs = [];
    for (var i = 0; i < parts.length; i++) if (typeof parts[i] === 'string') strs.push(parts[i]);
    return strs.join('\n');
  }
  if (c && typeof c === 'object' && c.content_type) return '[' + c.content_type + ']';
  return '[unknown]';
}

// 单节点消息投影；跳过的消息返回 null。
function webgptProjectMessage(m) {
  if (!m || typeof m !== 'object') return null;
  var role = (m.author && m.author.role) || '?';
  var text = __wzbMessageText(m);
  if (text === '') return null;
  return { role: role, text: text };
}

// transcript 主入口：输入 backend conversation document，输出 CLI transcript stdout 对象。
function webgptLinearize(d) {
  var b = webgptActiveBranch(d);
  if (!b.ok) return b;
  var msgs = [];
  for (var i = 0; i < b.node_ids.length; i++) {
    var node = d.mapping[b.node_ids[i]];
    if (!node) continue; // active branch 已校验存在，此处防御
    var p = webgptProjectMessage(node.message);
    if (p) msgs.push(p);
  }
  return {
    ok: true,
    title: d.title,
    create_time: d.create_time,
    turns: msgs.length,
    messages: msgs
  };
}
