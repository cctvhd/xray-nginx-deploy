import curses
import locale
import os
import sys
import time
import unicodedata

locale.setlocale(locale.LC_ALL, '')

# 数据目录 = 部署自己的目录 /etc/xray-deploy（cert.sh 总是显式把该目录作为 argv[1]
# 传入，两者一致）。
# 刻意【不用 /root 这类机器默认路径】，也刻意【不用脚本所在目录】：前者换台机器、
# 换个 $HOME 就报「找不到刚存下去的表」；后者在同一台机器上有两个答案 —— git 模式
# 是仓库根、curl 模式是 /etc/xray-deploy，两种启动方式会各看各的表。固定成
# /etc/xray-deploy 后两种模式同一处，且 config.txt / .config.tsv 里的 Cloudflare
# API 令牌明文完全不进 git 工作区（无 argv 直跑时尤其重要：旧兜底会把令牌写在仓库根）。
BASE_DIR = sys.argv[1] if len(sys.argv) > 1 else "/etc/xray-deploy"
os.makedirs(BASE_DIR, exist_ok=True)
SAVE_FILE = os.path.join(BASE_DIR, "config.txt")     # 对齐版,给人看
DATA_FILE = os.path.join(BASE_DIR, ".config.tsv")    # Tab 分隔,程序读取

data = [
    ["", "vless-xhttp", "example.com", "cdn"],
    ["", "vless-grpc", "", "cdn"],
    ["", "vless-xhttp-reality", "", "直连"],
    ["", "vless-reality", "", "直连"],
    ["", "Sing-Box AnyTLS", "", "直连"],
    ["", "Hysteria2", "", "直连"],
    ["", "Naiveproxy", "", "直连"],
]
FIXED_ROWS = len(data)          # 前面这些行的协议名不可改
for _ in range(3):              # 3 行空白备用行
    data.append(["", "", "", ""])

headers = ["API 令牌", "域名协议", "域名", "模式"]
FILE_HEADERS = ["API-TOKEN", "PROTOCOL", "DOMAIN", "MODE"]
MIN_W = [10, 10, 10, 6]
MAX_W = [30, 30, 24, 8]
ROW_LINES = True


def cw(ch):
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


def wlen(s):
    return sum(cw(ch) for ch in s)


def wrap(s, w):
    lines, cur, n = [], "", 0
    for ch in s:
        if n + cw(ch) > w:
            lines.append(cur)
            cur, n = "", 0
        cur += ch
        n += cw(ch)
    lines.append(cur)
    return lines


def tail(s, w):
    out, n = "", 0
    for ch in reversed(s):
        if n + cw(ch) > w:
            break
        out = ch + out
        n += cw(ch)
    return out


def trunc(s, w):
    if wlen(s) <= w:
        return s
    out, n = "", 0
    for ch in s:
        if n + cw(ch) > w - 1:
            break
        out += ch
        n += cw(ch)
    return out + "~"


def pad(s, w):
    return s + " " * max(0, w - wlen(s))


def center(s, w):
    total = max(0, w - wlen(s))
    left = total // 2
    return " " * left + s + " " * (total - left)


def safe_add(stdscr, y, x, text, attr=0):
    try:
        stdscr.addstr(y, x, text, attr)
    except curses.error:
        pass


LOAD_NOTE = ""

# ── 鼠标（单击选中 / 双击 = Enter，进入编辑或切换）────────────────────────
# 双击有**两条**路径，都得接住（实机 pty 探针实测出来的，不是猜的）：
#   ① 两次点击间隔在 ncurses 自己的 mouseinterval（约 166ms）**之内**：ncurses 会把
#      它们并成**一个** BUTTON1_DOUBLE_CLICKED 事件（中间的第一次单击被它吞掉），
#      自己数点击数在这里数不出来 —— 见 mouse_click 里对这个 bstate 的直接处理。
#   ② 间隔在 166ms~600ms 之间：终端给的是**两个**独立事件，ncurses 不认，只能自己
#      按时间窗判定。Python 的 curses 没暴露 curses.mouseinterval，调不了它的阈值，
#      所以慢速双击只可能靠自己这条路径兜住。
MOUSE_OK = False             # 终端不支持鼠标时保持 False，提示行也就不写「双击」那半句
MOUSE_DOUBLE_MS = 600
_last_click = (0.0, None)    # 上一次点击的 (时刻, (行,列))，只用来判双击
_last_event_t = 0.0          # 部分终端把一次物理点击报成「按下」+「抬起」两个事件，靠它并成一个
HIT_ROWS = []                # draw_table 记下的行落点 [(y, 行高, 行号)]
HIT_COLS = []                # 列落点 [(x, 列宽, 列号)]


def hit_test(my, mx):
    """屏幕坐标 → (行, 列)；落在表格外（提示行、边框、表格上下方）返回 None。"""
    r = None
    for y, h, ri in HIT_ROWS:
        if y <= my < y + h:
            r = ri
            break
    if r is None:
        return None
    for x, w, ci in HIT_COLS:
        if x <= mx < x + w + 2:      # 单元格含左右各一个空格
            return (r, ci)
    return None


def mouse_click():
    """取走一个鼠标事件，返回 ('move'|'edit', 行, 列) 或 None（事件一律取走，不能留）。"""
    global _last_click, _last_event_t
    try:
        _id, mx, my, _z, bstate = curses.getmouse()
    except curses.error:
        return None
    if not bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED |
                     curses.BUTTON1_RELEASED | curses.BUTTON1_DOUBLE_CLICKED |
                     curses.BUTTON1_TRIPLE_CLICKED):
        return None                  # 滚轮/中键等：忽略，但事件已取走
    now = time.monotonic()
    if bstate & (curses.BUTTON1_DOUBLE_CLICKED | curses.BUTTON1_TRIPLE_CLICKED):
        # 路径①：ncurses 已替我们认定是双击（快双击），直接进编辑。
        # 放在防抖判定之前 —— 它可能就是紧跟着上一个事件来的。
        _last_event_t = now
        _last_click = (0.0, None)
        hit = hit_test(my, mx)
        return None if hit is None else ("edit",) + hit
    if now - _last_event_t < 0.05:   # 同一次点击的「按下/抬起」：并成一个
        _last_event_t = now
        return None
    _last_event_t = now
    hit = hit_test(my, mx)
    if hit is None:
        return None
    t0, rc0 = _last_click
    double = rc0 == hit and (now - t0) <= MOUSE_DOUBLE_MS / 1000.0
    _last_click = (now, hit)
    return ("edit" if double else "move",) + hit


def load_file():
    """启动时读取上次保存的数据"""
    global LOAD_NOTE
    if not os.path.exists(DATA_FILE):
        # 必须吵：此时表格显示的是写死在源码里的默认值（example.com），
        # 看起来跟「读到了表」一模一样，曾因此被误判成「表没存上」查错方向。
        LOAD_NOTE = f"⚠ 未找到 {DATA_FILE} — 下表是内置默认值，不是本机配置！按 S 才会写出"
        return
    try:
        with open(DATA_FILE, "r", encoding="utf-8") as f:
            lines = [ln.rstrip("\n") for ln in f]
        for i, ln in enumerate(lines[:len(data)]):
            cells = ln.split("\t")
            cells += [""] * (4 - len(cells))
            row = cells[:4]
            if i < FIXED_ROWS:
                row[1] = data[i][1]              # 固定协议名不被覆盖
            if row[3] not in ("cdn", "直连", ""):
                row[3] = data[i][3]
            data[i] = row
        LOAD_NOTE = f"数据目录 {BASE_DIR}"
    except Exception as e:
        LOAD_NOTE = f"⚠ {DATA_FILE} 解析失败({e}) — 下表是内置默认值，不是本机配置！"


def save_file():
    # 1) 对齐版 config.txt(跳过全空的备用行)
    rows = [row for row in data if any(row)]
    ws = [max(len(FILE_HEADERS[c]), *(wlen(row[c]) for row in rows)) if rows
          else len(FILE_HEADERS[c]) for c in range(4)]
    with open(SAVE_FILE, "w", encoding="utf-8") as f:
        f.write("  ".join(center(FILE_HEADERS[c], ws[c]) for c in range(4)).rstrip() + "\n")
        for row in rows:
            f.write("  ".join(pad(row[c], ws[c]) for c in range(4)).rstrip() + "\n")
    os.chmod(SAVE_FILE, 0o600)

    # 2) 程序读取用的数据文件(保留所有行,包括空白备用行)
    with open(DATA_FILE, "w", encoding="utf-8") as f:
        for row in data:
            f.write("\t".join(row) + "\n")
    os.chmod(DATA_FILE, 0o600)


def calc_widths(screen_w):
    widths = []
    for c in range(4):
        w = max(wlen(headers[c]), *(wlen(row[c]) for row in data))
        widths.append(max(MIN_W[c], min(w, MAX_W[c])))
    while sum(widths) + 8 + 5 + 1 > screen_w:
        cand = [c for c in (0, 2) if widths[c] > 8]
        if not cand:
            break
        c = max(cand, key=lambda i: widths[i])
        widths[c] -= 1
    return widths


def draw_table(stdscr, ri, ci):
    stdscr.clear()
    sh, sw = stdscr.getmaxyx()
    widths = calc_widths(sw)
    del HIT_ROWS[:]
    del HIT_COLS[:]
    _x = 2                       # 第一列文字起点：1(左边框) + 1(边框与文字间的空格)
    for _c in range(4):          # 每列占 列宽+2(空格) 再加一根竖线
        HIT_COLS.append((_x, widths[_c], _c))
        _x += widths[_c] + 3

    heights = [max(len(wrap(row[c], widths[c])) for c in range(4)) for row in data]
    header_h = max(len(wrap(headers[c], widths[c])) for c in range(4))
    base = 1 + 1 + 1 + header_h + 1 + sum(heights) + 1 + 1 + 1
    row_lines = ROW_LINES and sh >= base + (len(data) - 1)

    def hline(y):
        safe_add(stdscr, y, 1, "+" + "+".join("-" * (w + 2) for w in widths) + "+")

    def row_block(y, cells, sel_c=None, bold=False):
        wrapped = [wrap(cells[c], widths[c]) for c in range(4)]
        h = max(len(x) for x in wrapped)
        for i in range(h):
            x = 1
            safe_add(stdscr, y + i, x, "|")
            x += 1
            for c in range(4):
                part = wrapped[c][i] if i < len(wrapped[c]) else ""
                cell = center(part, widths[c]) if bold else pad(part, widths[c])
                text = " " + cell + " "
                attr = curses.A_REVERSE if sel_c == c else (curses.A_BOLD if bold else 0)
                safe_add(stdscr, y + i, x, text, attr)
                x += widths[c] + 2
                safe_add(stdscr, y + i, x, "|")
                x += 1
        return h

    hint = "方向键移动 | Enter 编辑/切换 | S 保存 | Q 退出"
    if MOUSE_OK:
        hint = "方向键移动 | Enter 或鼠标双击 编辑/切换 | S 保存 | Q 退出"
    safe_add(stdscr, 0, 1, trunc(hint, sw - 2))
    # 数据目录/读取状态顶格单独一行：屏幕会被 clear()，cert.sh 在此之前打的
    # 「配置表目录: ...」日志会被抹掉，这行是唯一能当场判断读到哪去了的依据。
    note_attr = curses.A_BOLD if LOAD_NOTE.startswith("⚠") else curses.A_DIM
    safe_add(stdscr, 1, 1, trunc(LOAD_NOTE, sw - 2), note_attr)
    hline(2)
    y = 3 + row_block(3, headers, bold=True)
    hline(y)
    y += 1
    for r in range(len(data)):
        h = row_block(y, data[r], sel_c=ci if r == ri else None)
        HIT_ROWS.append((y, h, r))     # 行高随折行变化，只有这里知道落点
        y += h
        if row_lines and r < len(data) - 1:
            hline(y)
            y += 1
    hline(y)
    y += 1
    safe_add(stdscr, y, 1, trunc(f"当前 [{headers[ci]}]: {data[ri][ci]}", sw - 2))
    stdscr.refresh()
    return y + 1


def input_line(stdscr, y, prompt, default=""):
    buf = list(default)
    curses.curs_set(1)
    _, sw = stdscr.getmaxyx()
    while True:
        stdscr.move(y, 0)
        stdscr.clrtoeol()
        text = "".join(buf)
        avail = max(5, sw - 3 - wlen(prompt))
        shown = tail(text, avail)
        safe_add(stdscr, y, 1, prompt + shown)
        stdscr.move(y, min(1 + wlen(prompt) + wlen(shown), sw - 1))
        stdscr.refresh()
        try:
            ch = stdscr.get_wch()
        except curses.error:
            continue
        if isinstance(ch, str):
            if ch in ("\n", "\r"):
                break
            elif ch == "\x1b":
                curses.curs_set(0)
                return None
            elif ch in ("\x7f", "\b"):
                if buf:
                    buf.pop()
            elif ch.isprintable():
                buf.append(ch)
        else:
            if ch == curses.KEY_ENTER:
                break
            elif ch == curses.KEY_BACKSPACE and buf:
                buf.pop()
            elif ch == curses.KEY_MOUSE:
                # 编辑途中点鼠标：必须把事件取走。留着不取，下一次 get_wch 会立刻
                # 再吐一个 KEY_MOUSE，这里又不处理 → 空转死循环。
                try:
                    curses.getmouse()
                except curses.error:
                    pass
    curses.curs_set(0)
    return "".join(buf).strip()


def edit_cell(stdscr, r, c, input_y):
    global _last_click
    _last_click = (0.0, None)          # 编辑完清掉双击计时，免得改完随手再点一下又进编辑
    if c == 1 and r < FIXED_ROWS:      # 原有协议名不让改,备用行可以填
        return
    if c == 3:
        data[r][c] = "直连" if data[r][c] == "cdn" else "cdn"
        return
    new_val = input_line(stdscr, input_y, f"修改[{headers[c]}] Enter确定/Esc取消: ", data[r][c])
    if new_val is not None:
        data[r][c] = new_val


def main(stdscr):
    global MOUSE_OK
    load_file()
    curses.curs_set(0)
    stdscr.keypad(True)
    try:
        # 终端不支持鼠标时返回 0（此时终端也不会发鼠标序列，点击等于没点）
        MOUSE_OK = curses.mousemask(curses.ALL_MOUSE_EVENTS) != 0
    except curses.error:
        MOUSE_OK = False
    r, c = 0, 0
    while True:
        input_y = draw_table(stdscr, r, c)
        key = stdscr.getch()
        if key == curses.KEY_MOUSE:
            act = mouse_click()
            if act is None:
                continue
            r, c = act[1], act[2]
            if act[0] == "edit":       # 双击：与 Enter 同义
                edit_cell(stdscr, r, c, input_y)
            continue
        if key == curses.KEY_UP and r > 0:
            r -= 1
        elif key == curses.KEY_DOWN and r < len(data) - 1:
            r += 1
        elif key == curses.KEY_LEFT and c > 0:
            c -= 1
        elif key == curses.KEY_RIGHT and c < 3:
            c += 1
        elif key in (10, 13, curses.KEY_ENTER):
            edit_cell(stdscr, r, c, input_y)
        elif key in (ord("s"), ord("S")):
            # example.com 是源码里的占位符（RFC 2606 保留域），不是谁的域名。
            # 带着它保存 = 落盘一份「看起来正常」的空表，下游 _purge_stale_domains
            # 会把本机真实域名全判为陈旧、连证书一起删光（实机发生过）。
            # 这里拦一道，确认后才落盘。
            if any(r[2] == "example.com" for r in data):
                safe_add(stdscr, input_y, 1, "⚠ 还有一行是内置占位符 example.com，不是你自己的域名！")
                safe_add(stdscr, input_y + 1, 1, "  这样保存会删掉本机已注册的全部证书。按 Y 仍要保存 / 其它键返回修改")
                stdscr.refresh()
                if stdscr.getch() not in (ord("y"), ord("Y")):
                    continue
            save_file()
            safe_add(stdscr, input_y, 1, f"【保存成功!】已导出到 {SAVE_FILE},按任意键继续")
            stdscr.refresh()
            stdscr.getch()
        elif key in (ord("q"), ord("Q")):
            break


if __name__ == "__main__":
    curses.wrapper(main)
