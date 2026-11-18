"""打包前处理 Rime 方案（只做文本处理，不引入 YAML 库）：

- 删除所有 lua 组件（lua_processor / lua_translator / lua_filter / lua_segmentor）；
- 拼音和双拼方案接入语言模型（octagram），并打开按上下文选词；
- 中英混合词（如「我OK啊」）不做补全；
- 每页 8 个候选；
- 生成「五笔 86 + 拼音混输」方案（wubi86_pinyin）：五笔码和全拼可以混着打，候选旁显示五笔编码，方便学拆字；
- 每个方案再生成一个「_nolearn」版本（关闭个人词频记忆），设置里「关闭学习」时切到它；
- default.yaml 的 schema_list 只保留 SayFlow 带上的方案。

所有设置都在打包时写死并预编译，输入法运行时不再生成任何配置、不需要重新部署。
用法：python3 -I scripts/patch_schemas.py vendor/rime-data
"""
import pathlib
import re
import sys

LUA = re.compile(r"^\s*-\s*lua_(processor|translator|filter|segmentor)@")
SCHEMAS = ["rime_ice", "double_pinyin_flypy", "double_pinyin", "double_pinyin_mspy", "wubi86", "wubi86_pinyin"]
PINYIN = {"rime_ice", "double_pinyin", "double_pinyin_flypy", "double_pinyin_mspy"}
PAGE_SIZE = 8

GRAMMAR = """
# ---- SayFlow：语言模型（librime-octagram），本机运行 ----
grammar:
  language: wanxiang-lts-zh-hans
  collocation_max_length: 5
  collocation_min_length: 2
"""


def set_key(text: str, block: str, key: str, value: str) -> str:
    """在顶层块 block: 下设置 key: value（已有就改，没有就加在块的第一行）"""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.rstrip() == f"{block}:" or l.startswith(f"{block}: ") or l.startswith(f"{block}:  #")), None)
    if start is None:
        return text.rstrip("\n") + f"\n{block}:\n  {key}: {value}\n"
    end = start + 1
    while end < len(lines) and (not lines[end].strip() or lines[end].startswith((" ", "\t", "#"))):
        end += 1
    pattern = re.compile(rf"^  {re.escape(key)}:")
    for i in range(start + 1, end):
        if pattern.match(lines[i]):
            lines[i] = f"  {key}: {value}"
            return "\n".join(lines)
    lines.insert(start + 1, f"  {key}: {value}")
    return "\n".join(lines)


def clean(text: str) -> tuple[str, int]:
    lines = text.splitlines()
    kept = []
    for line in lines:
        if LUA.match(line):
            continue
        # 注释里提到 lua 组件的说明也去掉，避免误导
        if "lua_" in line and "#" in line:
            line = line[: line.index("#")].rstrip()
        kept.append(line)
    return "\n".join(kept) + "\n", len(lines) - len(kept)


def patch(path: pathlib.Path) -> None:
    schema_id = path.name.replace(".schema.yaml", "")
    text, removed = clean(path.read_text(encoding="utf-8"))
    # 五笔的拼音反查原本用 pinyin_simp 词库，这里改用已经带上的雾凇拼音词库
    text = text.replace("pinyin_simp", "rime_ice")
    # 五笔方案引用的 symbols.yaml 没带上，改为和雾凇一样从 default.yaml 取标点配置
    text = text.replace("import_preset: symbols\n", "__include: default:/punctuator\n")
    text = set_key(text, "menu", "page_size", str(PAGE_SIZE))
    if schema_id in PINYIN:
        if "\ngrammar:" not in text:
            text += GRAMMAR
        text = set_key(text, "translator", "contextual_suggestions", "true")
        text = set_key(text, "translator", "max_homophones", "7")
        text = set_key(text, "translator", "max_homographs", "7")
        if "\ncn_en:" in text:
            text = set_key(text, "cn_en", "enable_completion", "false")
    print(f"{path.name}: 去掉 {removed} 个 lua 组件")
    emit(path.parent, schema_id, text)
    if schema_id == "wubi86":
        emit(path.parent, "wubi86_pinyin", wubi_pinyin(text))


MIXED_BLOCKS = """
# ---- SayFlow：五笔 + 拼音混输 ----
pinyin:
  dictionary: rime_ice
  prism: rime_ice
  initial_quality: 0.5
  enable_completion: false
  enable_sentence: true

wubi_code:
  dictionary: wubi86
  overwrite_comment: true
  comment_format:
    - "xform/^/〔/"
    - "xform/$/〕/"
"""


def wubi_pinyin(text: str) -> str:
    """在五笔方案基础上加一个全拼翻译器：不会拆的字直接打全拼；所有候选旁显示五笔编码"""
    text = text.replace("  schema_id: wubi86\n", "  schema_id: wubi86_pinyin\n", 1)
    text = re.sub(r'^  name: .*$', '  name: "五笔86＋拼音"', text, count=1, flags=re.M)
    # 混输时五笔码不造句，避免把拼音字母拆成五笔码拼出一串怪词
    text = set_key(text, "translator", "enable_sentence", "false")
    text = text.replace("    - table_translator\n",
                        "    - table_translator\n    - script_translator@pinyin\n  filters:\n    - reverse_lookup_filter@wubi_code\n", 1)
    return text + MIXED_BLOCKS


def emit(folder: pathlib.Path, schema_id: str, text: str) -> None:
    (folder / f"{schema_id}.schema.yaml").write_text(text, encoding="utf-8")
    if schema_id in SCHEMAS:
        nolearn = text.replace(f"  schema_id: {schema_id}\n", f"  schema_id: {schema_id}_nolearn\n", 1)
        nolearn = set_key(nolearn, "translator", "enable_user_dict", "false")
        (folder / f"{schema_id}_nolearn.schema.yaml").write_text(nolearn, encoding="utf-8")
        print(f"{schema_id}: 已生成（含关闭学习版本）")


def patch_default(path: pathlib.Path) -> None:
    """schema_list 只保留 SayFlow 带上的方案和它们的「关闭学习」版本；每页 7 个候选"""
    lines = path.read_text(encoding="utf-8").splitlines()
    out, skipping = [], False
    ids = SCHEMAS + [s + "_nolearn" for s in SCHEMAS]
    for line in lines:
        if line.startswith("schema_list:"):
            out.append("schema_list:")
            out.extend(f"  - schema: {s}" for s in ids)
            skipping = True
            continue
        if skipping:
            if line.startswith((" ", "\t")) or not line.strip():
                continue
            skipping = False
        out.append(line)
    text = "\n".join(out) + "\n"
    text = set_key(text, "menu", "page_size", str(PAGE_SIZE))
    path.write_text(text, encoding="utf-8")
    print("default.yaml: schema_list =", ", ".join(ids))


def main() -> None:
    root = pathlib.Path(sys.argv[1])
    patch_default(root / "default.yaml")
    for path in sorted(root.glob("*.schema.yaml")):
        if path.name.endswith("_nolearn.schema.yaml") or path.name == "wubi86_pinyin.schema.yaml":
            continue
        patch(path)


if __name__ == "__main__":
    main()
