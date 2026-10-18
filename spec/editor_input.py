import os
import select
import subprocess
import tempfile
import time

import msgpack

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
data = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
paths = [
    root,
    os.environ.get("TODO_NUI_PATH", data + "/nvim/lazy/nui.nvim"),
    os.environ.get("TODO_SQLITE_PATH", data + "/nvim/lazy/sqlite.lua"),
]
state = tempfile.TemporaryDirectory(prefix="todo-editor-input-")
environment = dict(os.environ, XDG_STATE_HOME=state.name)
p = subprocess.Popen(
    [
        "nvim",
        "--clean",
        "--headless",
        "--embed",
        "--cmd",
        "set rtp+=" + ",".join(paths),
    ],
    env=environment,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
u = msgpack.Unpacker(raw=False, strict_map_key=False)
seq = 0
messages = []


def rpc(method, args=None):
    args = [] if args is None else args
    global seq
    seq += 1
    ident = seq
    p.stdin.write(msgpack.packb([0, ident, method, args], use_bin_type=True))
    p.stdin.flush()
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        ready, _, _ = select.select([p.stdout], [], [], 0.2)
        if not ready:
            continue
        data = os.read(p.stdout.fileno(), 65536)
        if not data:
            raise RuntimeError("Neovim exited: " + p.stderr.read().decode())
        u.feed(data)
        for event in u:
            if event[0] == 2 and event[1] == "redraw":
                for entry in event[2]:
                    if entry[0] == "msg_show":
                        for msg in entry[1:]:
                            if msg[0] in ("emsg", "lua_error", "echoerr"):
                                messages.append("".join(part[1] for part in msg[1]))
            if event[0] == 1 and event[1] == ident:
                if event[2]:
                    raise RuntimeError(event[2])
                return event[3]
    raise RuntimeError("RPC timeout " + method)


def lua(code):
    return rpc("nvim_exec_lua", [code, []])


def keys(text):
    rpc("nvim_input", [text])
    time.sleep(0.06)
    return rpc("nvim_get_mode")


try:
    rpc("nvim_ui_attach", [140, 45, {"ext_linegrid": True, "ext_messages": True}])
    lua("""require('todo.config').setup({db_path=vim.fn.tempname()..'.db',reminders={enabled=false},ai={enabled=true,api_key='mock-editor'}})
 local todo=require('todo');local svc=todo._service();local ws=svc.store.workspace
 local ai=require('todo.ai').new(ws,svc,{transport=function(opts,cb)
 _G.sent_count=(_G.sent_count or 0)+1
 vim.defer_fn(function() cb(nil,{choices={{finish_reason='stop',message={content=vim.json.encode({action='draft',summary='收到',changes={}})}}},usage={prompt_tokens=1,completion_tokens=1}}) end,30)
 return {cancel=function()end} end})
 todo._ai=function()return ai end
 _G.ai=ai;_G.ui=require('todo.ui.planner');_G.owner=ui.chat();_G.sid=ws:list('conversation')[1].key
 """)
    assert keys("i")["mode"] == "i", "i did not open the answer editor in Insert mode"
    assert lua("return vim.bo.modifiable"), "answer editor must be editable"
    keys("real insert text<Tab>kept")
    keys("<Esc><CR>")
    assert rpc("nvim_get_mode")["mode"] == "n", "saving did not leave Insert mode"
    assert lua("return vim.bo.modifiable") is False, "chat should stay readonly"
    assert lua("return sent_count") == 1, "answer sent more than once"
    assert "real insert text" in lua("return ai:resume(sid).messages[1].content")
    assert not messages, messages
    # Cancel in actual Insert mode without sending another request.
    keys("i")
    keys("discard")
    keys("<C-q>")
    assert rpc("nvim_get_mode")["mode"] == "n"
    assert lua("return sent_count") == 1
    assert not messages, messages
    # A rejected response must be reported once, by the operation feedback layer.
    lua("""_G.notices={};vim.notify=function(message) notices[#notices+1]=message end
 ai.opts.transport=function(opts,cb)
 vim.defer_fn(function() cb(nil,{choices={{finish_reason='stop',message={content=vim.json.encode({action='draft',changes={{kind='plan_add',task_ref='invented',after={minutes=15}}}})}}}}) end,20)
 return {cancel=function()end} end""")
    keys("g")
    for _ in range(100):
        if not lua("return ai.active[sid] ~= nil"):
            break
        time.sleep(0.02)
    rpc("nvim_get_mode")
    assert lua("return #notices") == 1, (
        "AI notifications: "
        + str(lua("return notices"))
        + " active: "
        + str(lua("return ai:resume(sid).status"))
    )
    assert "Invalid AI response" in lua("return notices[1]")
    print(
        "ok - attached UI: Insert save/cancel, i answer, native Tab and one failure notification"
    )
    # The daily composer is a real Vim buffer and persists across round changes.
    lua("""ui.close();_G.daily_calls=0
 local svc=require('todo')._service();local ws=svc.store.workspace
 assert(svc:create({title='Daily native editor',description='A complete task'}))
 ai.opts.transport=function(opts,cb)
 daily_calls=daily_calls+1
 local snapshot=vim.json.decode(opts.body.messages[2].content:match('Workspace snapshot:\\n(.*)'))
 vim.defer_fn(function()
 local result
 if daily_calls==1 then result={message='Choose',action='question',questions={{id='goal',header='Goal',question='Which goal?',options={{id='a',label='First'},{id='b',label='Second'}}}}}
 elseif snapshot.reviews then result={message='Ready',action='draft',summary='Ready',changes={}}
 else result={message='Checked',action='item_review',summary='Clear',review={minutes=20,next_action='Start',completion='Done'},changes={}} end
 result.understanding={goal_clear=true,goal='Complete task',deliverable='Done',unknowns={},evidence={snapshot.tasks[1].title}}
 cb(nil,{choices={{finish_reason='stop',message={content=vim.json.encode(result)}}},usage={prompt_tokens=10,completion_tokens=5}})
 end,60)
 return {running=true,cancel=function()cb('cancelled')end} end
 _G.daily=require('todo').plan();_G.intent_buf=daily.composer.bufnr
 """)
    assert rpc("nvim_get_mode")["mode"] == "n"
    keys("<CR>")  # Confirm preparation locks.
    lua("daily.focus_input(false)")
    assert lua("return vim.bo.modifiable")
    keys("iNative Vim text<Esc>")
    keys("u")
    assert lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)") == [""]
    keys("<C-r>")
    assert "Native Vim text" in lua("return vim.api.nvim_get_current_line()")
    assert keys("<C-v>")["mode"] == "\x16", "Normal Ctrl-v must retain block selection"
    keys("<Esc>")
    keys("A<CR>second<Tab>line")
    assert rpc("nvim_get_mode")["mode"] == "i"
    keys("<Esc><CR>w")
    for _ in range(100):
        if lua("return daily.controller.state.status=='awaiting' and not daily.controller.busy"):
            break
        time.sleep(.03)
    assert lua("return daily.controller.state.status") == "awaiting"
    assert lua("return vim.api.nvim_buf_get_lines(intent_buf,0,-1,false)")[0] == "Native Vim text"
    # Real key dispatch must ignore competing global h/l prefixes immediately.
    lua("vim.keymap.set('n','lx',function()end); vim.keymap.set('n','hx',function()end); vim.o.timeoutlen=1000")
    lua("vim.api.nvim_set_current_win(daily.questions.winid)")
    latency=[]
    for key, target in [("l", 2), ("h", 1)] * 12:
        start=time.monotonic()
        rpc("nvim_input", [key])
        while lua("return daily.tab") != target:
            assert time.monotonic()-start < .2, "question switch waited for mapping timeout"
        latency.append((time.monotonic()-start)*1000)
    p95=sorted(latency)[int(len(latency)*.95)-1]
    assert p95 < 50, f"input feedback P95 {p95:.2f} ms"
    # Read a streamed reply without changing the composer's input mode/cursor.
    lua("daily.controller.partial=string.rep('Long AI context line\\n',150);daily.render();daily.focus_input(true)")
    input_win=rpc("nvim_get_current_win")
    keys("draft text")
    input_cursor=rpc("nvim_win_get_cursor", [input_win])
    keys("<C-M-u>")
    assert rpc("nvim_get_current_win")==input_win
    assert rpc("nvim_get_mode")["mode"]=="i"
    assert rpc("nvim_win_get_cursor", [input_win])==input_cursor
    assert lua("return daily.follow_reply")==False
    top=lua("return vim.api.nvim_win_call(daily.timeline.winid, vim.fn.winsaveview).topline")
    lua("daily.controller.partial=daily.controller.partial..'New stream token';daily.render()")
    assert lua("return vim.api.nvim_win_call(daily.timeline.winid,vim.fn.winsaveview).topline")==top
    assert lua("return daily.unread_reply")
    keys("<C-M-g>")
    assert lua("return daily.follow_reply and not daily.unread_reply")
    keys("<Esc><CR>")
    # Ctrl-j/k changes focus in Normal mode, without escaping to another window.
    keys("<C-j>")
    assert lua("return vim.api.nvim_get_current_win()==daily.composer.winid")
    keys("<C-k>")
    assert lua("return vim.api.nvim_get_current_win()==daily.questions.winid")
    print(f"ok - actual h/l P95 {p95:.2f} ms, controlled Ctrl focus, streaming read preserves Insert and viewport")
    # Custom answer, Normal return + preview/Enter, async task finish and final assembly.
    lua("daily.focus_input(true)")
    keys("Answer with detail<CR>another line<Esc><CR>w<CR>")
    for _ in range(100):
        if lua("return daily.controller.state.status=='review' and not daily.controller.busy"):
            break
        time.sleep(.03)
    assert lua("return daily.controller.state.status") == "review", lua("return daily.controller.state.last_error")
    assert lua("return daily_calls") == 3
    assert not messages, messages
    keys("<C-q>")
    assert lua("return require('todo.ui.daily').inspect_state()==nil")
    print("ok - attached daily UI: native undo/redo, block selection, Insert newline/Tab, explicit return/preview/send, async advance and no E21")
    # Mouse clicks/drag and global Ctrl navigation cannot move dashboard focus.
    lua("vim.o.mouse='a';_G.escaped=0;vim.keymap.set('n','<C-h>',function()escaped=escaped+1 end);require('todo.ui.panel').open({mode='float'});_G.panel=require('todo.ui.panel').inspect_state().owner")
    panel_win=rpc("nvim_get_current_win")
    panel_cursor=rpc("nvim_win_get_cursor",[panel_win])
    pos=lua("return vim.api.nvim_win_get_position(panel.detail.winid)")
    for action in ["press","drag","release"]:
        rpc("nvim_input_mouse",["left",action,"",0,pos[0]+2,pos[1]+2])
        time.sleep(.02)
    assert rpc("nvim_get_current_win")==panel_win
    assert rpc("nvim_win_get_cursor",[panel_win])==panel_cursor
    for key in ["<C-h>","<C-j>","<C-k>","<C-l>"]:
        keys(key)
        assert rpc("nvim_get_current_win")==panel_win
    assert lua("return escaped")==0
    lua("require('todo.ui.panel').close()")
    keys("<C-h>")
    assert lua("return escaped")==1, "dashboard changed global mapping"
    assert not messages, messages
    print("ok - real mouse press/drag/release and Ctrl guards; global mapping remains intact")
finally:
    p.terminate()
    p.wait(timeout=3)
    state.cleanup()
