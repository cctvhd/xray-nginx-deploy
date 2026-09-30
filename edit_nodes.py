import curses
import locale
import os
import sys
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


def load_file():
    """启动时读取上次保存的数据"""
    if not os.path.exists(DATA_FILE):
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
    except Exception:
        pass


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

    heights = [max(len(wrap(row[c], widths[c])) for c in range(4)) for row in data]
    header_h = max(len(wrap(headers[c], widths[c])) for c in range(4))
    base = 1 + 1 + header_h + 1 + sum(heights) + 1 + 1 + 1
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

    safe_add(stdscr, 0, 1, trunc("方向键移动 | Enter 编辑/切换 | S 保存 | Q 退出", sw - 2))
    hline(1)
    y = 2 + row_block(2, headers, bold=True)
    hline(y)
    y += 1
    for r in range(len(data)):
        y += row_block(y, data[r], sel_c=ci if r == ri else None)
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
    curses.curs_set(0)
    return "".join(buf).strip()


def edit_cell(stdscr, r, c, input_y):
    if c == 1 and r < FIXED_ROWS:      # 原有协议名不让改,备用行可以填
        return
    if c == 3:
        data[r][c] = "直连" if data[r][c] == "cdn" else "cdn"
        return
    new_val = input_line(stdscr, input_y, f"修改[{headers[c]}] Enter确定/Esc取消: ", data[r][c])
    if new_val is not None:
        data[r][c] = new_val


def main(stdscr):
    load_file()
    curses.curs_set(0)
    stdscr.keypad(True)
    r, c = 0, 0
    while True:
        input_y = draw_table(stdscr, r, c)
        key = stdscr.getch()
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
            save_file()
            safe_add(stdscr, input_y, 1, f"【保存成功!】已导出到 {SAVE_FILE},按任意键继续")
            stdscr.refresh()
            stdscr.getch()
        elif key in (ord("q"), ord("Q")):
            break


if __name__ == "__main__":
    curses.wrapper(main)
