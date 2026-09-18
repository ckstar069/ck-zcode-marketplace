// webgpt-zcode-bridge common page layer — verify 算法（纯函数，无页面 API）。
// 依据 spec/page-contract.md §18 与 spec/cli-contract.md §10：
//   比较只做换行正规化（\r\n → \n、裸 \r → \n），禁止 trim/折叠/Unicode normalize/小写/JS escaping；
//   pre current_node 必须仍在 post active branch，否则 verify_branch_changed；
//   只看 pre node-id set 之外的新节点，role=user，文本精确相等；
//   恰好 1 个 → success；多于 1 个 → ambiguous；0 个 → no_match（由 CLI 轮询到超时映射 verify_timeout）。
// 依赖 transcript.js（webgptActiveBranch / __wzbMessageText）。

function webgptNormalizeNewlines(s) {
  return String(s).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

// 从 conversation document 提取 verify 所需状态：
// {ok:true, current_node, node_ids:[全部 mapping key], branch:[active branch 节点列表]}
// branch 节点形状与 tests/fixtures/verify-cases.json 的 post_active_branch 一致：
// {node_id,parent,role,text,message_id,create_time}（message 为 null 时 role/text/message_id/create_time 为 null）。
function webgptVerifyState(d) {
  var b = webgptActiveBranch(d);
  if (!b.ok) return b;
  var branch = [];
  for (var i = 0; i < b.node_ids.length; i++) {
    var id = b.node_ids[i];
    var node = d.mapping[id];
    var m = node.message;
    branch.push({
      node_id: id,
      parent: (node.parent === undefined || node.parent === null) ? null : node.parent,
      role: m ? ((m.author && m.author.role) || '?') : null,
      text: m ? __wzbMessageText(m) : null,
      message_id: m ? (m.id === undefined ? null : m.id) : null,
      create_time: m ? (m.create_time === undefined ? null : m.create_time) : null
    });
  }
  var nodeIds = Object.keys(d.mapping);
  return { ok: true, current_node: d.current_node, node_ids: nodeIds, branch: branch };
}

// 核心比对。branchNodes 形状同 webgptVerifyState().branch（fixture 直接提供同构数据）。
// 返回 {status:'success',candidate:{node_id,message_id,create_time}}
//     | {status:'ambiguous'} | {status:'no_match'} | {status:'branch_changed'}
function webgptVerifyCheck(preCurrentNode, preNodeIds, branchNodes, message) {
  var onBranch = {};
  var i;
  for (i = 0; i < branchNodes.length; i++) onBranch[branchNodes[i].node_id] = 1;
  if (!onBranch[preCurrentNode]) return { status: 'branch_changed' };
  var pre = {};
  for (i = 0; i < preNodeIds.length; i++) pre[preNodeIds[i]] = 1;
  var norm = webgptNormalizeNewlines(message);
  var candidates = [];
  for (i = 0; i < branchNodes.length; i++) {
    var n = branchNodes[i];
    if (pre[n.node_id]) continue;
    if (n.role !== 'user') continue;
    if (webgptNormalizeNewlines(n.text) === norm) {
      candidates.push({ node_id: n.node_id, message_id: n.message_id, create_time: n.create_time });
    }
  }
  if (candidates.length === 1) return { status: 'success', candidate: candidates[0] };
  if (candidates.length > 1) return { status: 'ambiguous' };
  return { status: 'no_match' };
}
