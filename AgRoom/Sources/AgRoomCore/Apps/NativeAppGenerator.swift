import Foundation

/// The conversation model authors the definition; these helpers never start another LLM request.
public enum NativeAppGenerator {
    public static let designInstructions = """
    Design a small native AgRoom macOS app. Return ONLY one complete JSON definition.
    This is a finite native UI language. Use DSL version 1 for basic apps, 2 for offline Python, 3 for declared host capabilities and workflows, or 4 for interactive sliding-block boards.
    No Swift, JavaScript, embedded HTML, arbitrary tools or external file paths. URLs are data inputs; network access requires declared host capabilities.
    Required top-level fields: manifest, i18n, state, dataSources, views, actions. Version 2 adds optional scripts; version 3 adds optional capabilities; version 4 adds optional boards.
    manifest: id (lowercase ASCII letters, digits, hyphens, <=64 chars), version (positive integer), dslVersion:1, 2, 3 or 4,
    nameKey, summaryKey (i18n keys), icon (SF Symbol name), optional width (480...1600), height (360...1200).
    i18n: en, zh-Hans, zh-Hant, es, fr, ar, ru dictionaries for newly created apps. Existing definitions containing only en, zh-Hans and zh-Hant remain valid. Every label key must exist, translated and nonempty in every provided language.
    state: dictionary of {initial: string|boolean|number, persistent: boolean}. <=32 fields, <=32KiB per string.
    dataSources: dictionary of {kind:"knowledge", searchKey: optional string state key, pageSize:1...50}.
    dataSources also supports {kind:"records",collection:"collection-id",searchKey:optional string state key,pageSize:1...50}.
    records are private to this app and space, saved in its own SQLite database. Knowledge is a shared space resource.
    A list selects a record and loads its title/content. The host provides a separate app file manager.
    views: one node tree. Each node has a globally unique lowercase id and type.
    Types: vstack/hstack (children array), divider, text (textKey OR binding),
    textField/textEditor/toggle (textKey and stateKey), picker (textKey, stateKey, options array of i18n keys),
    button (textKey, action), list (source: dataSources key).
    Optional text style: title, headline, secondary. No other properties are supported.
    A binding is exactly ONE of {"literal": primitive}, {"state":"state-key"}, {"selection":"source-key.title"} or {"selection":"source-key.content"}.
    actions: dictionary of {type:"refresh",source:"source-key"},
    {type:"setState",stateKey:"key",value:binding}, or
    {type:"saveKnowledge",values:{title:binding,content:binding}}.
    For local button interactions use {type:"transformState",stateKey:"string-state",operation:"append",value:binding}
    to append text, {type:"transformState",stateKey:"string-state",operation:"removeLast"} to delete the last character,
    or {type:"transformState",stateKey:"result-string",operation:"calculate",value:{state:"expression-string"}}.
    calculate is a bounded decimal arithmetic parser: numbers, parentheses, unary +/- and + - * / (also − × ÷).
    It has no code, variables, functions, file access or side effects. Invalid input/division by zero preserves the previous result.
    These local state actions run instantly in preview and installed apps without Python, model calls or execution approval.
    A full calculator keypad should append digits/operators to expression state, use calculate for equals, setState to clear/copy results.
    Prefer these native actions for simple interactions; never use Python per digit or basic calculation.
    Additional actions:
    {type:"saveRecord",source:"records-source",values:{title:binding,content:binding,optional-other-field:binding}},
    {type:"deleteRecord",source:"records-source"},
    {type:"newRecord",source:"records-source",fields:{title:"title-state-key",content:"body-state-key"}},
    {type:"editRecord",source:"records-source",fields:{title:"title-state-key",content:"body-state-key"}},
    {type:"saveFile",values:{name:binding,content:binding}} for a UTF-8 file in the app's private files.
    Business data writes require host confirmation; local state edits do not. saveRecord updates the currently edited record with a revision check, otherwise creates one.
    newRecord clears the editor, editRecord loads the selected record, deleteRecord deletes only the selected record.
    saveKnowledge explicitly publishes a NEW shared knowledge entry; it does not save private app records.
    DSL v3 can call declared host capabilities (including native MySQL metadata), consume structured result sources,
    render tables and chain bounded actions. Read section=capabilities and example=database for this contract.
    Do not downgrade a requested online database app to file import without explaining the available host connector.
    No arbitrary SQL, external directory access or AI actions.
    All ordinary interactions are deterministic. Network access is mediated by declared host capabilities; Python stays offline.
    <=128 nodes, depth <=12, <=8 dataSources, <=32 actions, <=256 translation keys per language.
    Keep existing persistent state keys/types on updates. New persistent fields may be added with initial values. manifest.dataVersion is 1.
    For a working JSON example call apps_schema with section=example and example=note, calculator or python.
    For Python functions first read section=python. For updates read section=current with app_id.
    For Klotski, sliding-block puzzles, or interactive boards, read section=boards and example=slidingPuzzle. DSL v4 inherits v3 capabilities.
    Follow next_offset until a section is complete; do not invent omitted schema or repeat completed sections.
    """

    public static let boardInstructions = """
    DSL v4 adds optional boards, a dictionary of <=4 typed rectangular sliding-block boards. It inherits DSL v1/v2/v3 features.
    Each board: {columns:2...12,rows:2...12,persistent:boolean,pieces:[...],goal:{piece:"piece-id",x:integer,y:integer}}.
    A piece: {id:"unique-id",labelKey:"i18n-key",x:integer,y:integer,width:positive-integer,height:positive-integer,axis:optional "both"|"horizontal"|"vertical"}.
    Coordinates are zero-based integer cells. <=32 pieces per board; no overlaps, duplicate IDs, out-of-bounds pieces or unknown fields.
    The goal names one existing piece and its target top-left coordinate inside the board. Reaching it wins; pieces never leave the board.
    Every piece label must have a nonempty translation in every provided language. Labels and piece order may change on update; persistent board IDs, dimensions, piece IDs/sizes/initial positions/axes and goal must remain compatible.
    Render with {id:"game-view",type:"board",board:"board-id"}. The host provides proportional layout, grid snapping, collision-clamped dragging,
    selectable blocks, arrow-key and accessible direction controls, a move counter and a conditional victory message.
    Each move is a single horizontal or vertical slide. The host checks EVERY intermediate cell and commits position, move count, undo/redo history and victory together.
    Local gameplay never calls a model, Python, host capabilities or business write tools; it works fully in preview. Preview never persists progress.
    Add ordinary buttons with actions {type:"boardUndo",board:"board-id"}, {type:"boardRedo",board:"board-id"}, {type:"boardReset",board:"board-id"}.
    Undo/redo buttons are disabled when unavailable. After victory, undo or reset can continue play. Each straight slide counts as one move; undo decrements it, redo restores it.
    History retains the latest 128 moves; a new move after undo clears the redo branch. Keep structured progress out of scalar strings.
    A binding may alternatively be {board:"board-id.moves"} (number), {board:"board-id.won"}, {board:"board-id.canUndo"} or {board:"board-id.canRedo"} (bool).
    Persistent board progress shares the app's existing 64KiB draft budget and isolation/backup/restore lifecycle. Incompatible updates fail without clearing progress.
    This is a finite ruleset, not a general canvas, expression interpreter, event script, physics engine, solver, timer, network API or arbitrary object state.
    Read example=slidingPuzzle for a complete playable classic Klotski app. Custom levels must be independently checked for solvability; structural validation does not prove it.
    """

    public static let pythonInstructions = """
    DSL v2 scripts: dictionary (<=16) of {source:Python source <=64KiB,inputTypes:{name:"string"|"bool"|"number"},
    outputTypes:{name:"string"|"bool"|"number"},requirements:optional array of distribution/version requirements,
    timeoutSeconds:optional integer 1...120 (default 30)}. Keys use the same lowercase id rules as state.
    Define def main(inputs, context) returning EXACTLY the declared output dictionary. No automatic execution on load or install.
    Action: {type:"runPython",script:"script-id",inputs:{input-name:binding},resultBindings:{state-key:"output-name"},
    recordInputs:optional {input-name:{source:"records-source",limit:1...1000}},fileInputs:optional {input-name:binding}}.
    inputs must exactly match inputTypes; resultBindings destinations must have matching declared state types.
    context["records"][input-name] is a frozen list of complete records (id,collection,title,content,fields,revision,updatedAt),
    filtered by the source's current search state. Queries beyond limit or byte budget fail; no partial-page statistics.
    context["files"][input-name] supplies name,path,byteCount,sha256,id for a frozen read-only app attachment.
    fileInputs bindings resolve app file UUID strings. Add {id,type:"filePicker",textKey,stateKey:string-state-key} to choose an imported attachment.
    Use pathlib.Path(context["files"]["input-name"]["path"]) to read bytes; do not treat UUIDs or display names as paths.
    Write generated files directly inside context["outputDirectory"] (flat names, <=16 files, <=16MiB each, <=32MiB total).
    The host displays generated artifacts with explicit Save buttons. Returning outputs does not save records or publish knowledge;
    bind outputs to state and provide ordinary saveRecord/saveKnowledge actions when needed.
    Before first execution, the host reviews all scripts for repeated offline use with arbitrary inputs. Approved code is signed and revalidated on every run; changed code or environments require a fresh review. Uncertain/unavailable review offers explicit authorization of the entire installed version or a single run; rejected code cannot execute. Manual version authorization is signed separately from model approval and remains valid for changing inputs. Revocation and code/environment changes invalidate it.
    Functions use the current space's Python environment, offline, without child processes. Business writes and host capabilities retain their separate approvals.
    Missing dependencies are reported without execution; users install them through existing Python settings / approved package tools.
    Inputs and outputs are bounded; output JSON <=128KiB, each string <=32KiB. Do not encode tables or binary files into persistent state.
    Preview never runs functions. Syntax validation does not prove business correctness.
    DSL v3 runPython may add dataInputs:{input-name:"result-source"}. Frozen complete tables are in context["data"][input-name],
    with columns, rows (id,title,content,fields), hasMore. Partial pages are refused. No host tool, connection secret or network API is exposed to Python.
    """

    public static let capabilityInstructions = """
    DSL v3 host capabilities. This is a host-managed interface, not arbitrary tool execution.
    Add capabilities:{alias:{name:"catalog-name",version:1,resource:optional "slot-id"}}.
    Only catalog names/versions are valid. All inputs and output bindings are type checked. Never embed passwords or connection settings.
    MySQL capabilities require resource:"slot-id" and a view {id,type:"resourcePicker",textKey,resource:"slot-id"}.
    The user chooses a space-specific host connection; the slot is not a state key and cannot be assigned by the app or Python.
    Connections are configured in the host Database page or via Manage Connections beside the picker. Remote MySQL requires verified TLS.
    Add dataSources:{tables:{kind:"result",pageSize:50}} for a transient table result.
    Action {type:"callCapability",capability:"alias",inputs:{input-name:binding},source:optional "result-source",resultBindings:optional {state-key:"output-name"}}.
    inputs exactly cover the catalog input schema. source is required iff the descriptor has tableColumns.
    Bind selection with {selection:"source.title"}, {selection:"source.content"}, or {selection:"source.column-name"}.
    Views {id,type:"list",source} and {id,type:"table",source} select a row. Table columns have host-provided localized headers.
    Result tables are complete and bounded; knowledge search exposes offset input and next-offset output (-1 at end).
    Never put table JSON into persistent scalar state. For Python use dataInputs and context["data"].
    Action {type:"sequence",steps:["existing-action-id",...]} executes 1...16 steps in order, waiting for each output and approval.
    Steps may be callCapability,runPython,saveFile,saveRecord,saveKnowledge; no nested sequences, loops or automatic retries.
    Failure, denial, cancellation or resource change stops the sequence. External effects cannot be rolled back by a sequence.
    Installed capability declarations are shown during install/update; host resource selection and per-call confirmation still apply.
    MySQL and public web reads require fresh manual approval; clipboard writes require confirmation; local knowledge reads remain scoped to this space.
    Preview never contacts tools, databases, clipboard or Python. Network/clipboard writes are not Python APIs.
    """

    public static func validateOutput(_ text: String, updating existing: NativeAppDefinition? = nil) throws -> NativeAppDefinition {
        let result = try decodeOutput(text)
        if let existing {
            guard result.id == existing.id, result.manifest.version > existing.manifest.version,
                  result.acceptsStateSchema(of: existing), result.dataVersion == existing.dataVersion else {
                throw NativeAppError(.incompatibleState)
            }
        }
        return result
    }

    static func decodeOutput(_ text: String) throws -> NativeAppDefinition {
        guard text.utf8.count <= NativeAppDefinition.maximumBytes else { throw NativeAppError(.tooLarge) }
        let cleaned = SkillGenerator.stripReasoningBlocks(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a single JSON fence, but never select a convenient object from prose.
        let json: String
        if cleaned.hasPrefix("```"), cleaned.hasSuffix("```"), let newline = cleaned.firstIndex(of: "\n") {
            json = String(cleaned[cleaned.index(after: newline)..<cleaned.index(cleaned.endIndex, offsetBy: -3)])
        } else { json = cleaned }
        return try NativeAppDefinition.decode(Data(json.utf8))
    }
}

public enum NativeAppTemplates {
    public static func note() throws -> NativeAppDefinition { try NativeAppDefinition.decode(Data(noteJSON.utf8)) }
    public static func textStatistics() throws -> NativeAppDefinition { try NativeAppDefinition.decode(Data(textStatisticsJSON.utf8)) }
    public static func knowledge() throws -> NativeAppDefinition {
        var app = try note()
        app.manifest.id = "knowledge-browser"
        app.manifest.icon = "books.vertical"
        app.manifest.width = 960
        for (language, name, summary) in [
            ("en", "Knowledge Browser", "Search and read knowledge in this space."),
            ("zh-Hans", "知识浏览", "搜索、浏览当前空间的知识条目。"),
            ("zh-Hant", "知識瀏覽", "搜尋、瀏覽目前空間的知識條目。"),
            ("es", "Explorador de conocimiento", "Busca y lee el conocimiento de este espacio."),
            ("fr", "Explorateur de connaissances", "Recherchez et lisez les connaissances de cet espace."),
            ("ar", "متصفح المعرفة", "ابحث في معارف هذا الفضاء واقرأها."),
            ("ru", "Обзор знаний", "Поиск и чтение знаний этого пространства.")
        ] { app.i18n[language]?["name"] = name; app.i18n[language]?["summary"] = summary }
        for (language, label) in [("en", "Search knowledge"), ("zh-Hans", "搜索知识"), ("zh-Hant", "搜尋知識"),
                                  ("es", "Buscar conocimiento"), ("fr", "Rechercher des connaissances"),
                                  ("ar", "البحث في المعرفة"), ("ru", "Поиск знаний")] {
            app.i18n[language]?["search"] = label
        }
        // Build through the same decoder/validator used by external definitions.
        let nodeJSON = #"{"id":"root","type":"vstack","children":[{"id":"search","type":"textField","textKey":"search","stateKey":"query"},{"id":"columns","type":"hstack","children":[{"id":"results","type":"list","source":"knowledge"},{"id":"detail","type":"vstack","children":[{"id":"selected-title","type":"text","binding":{"selection":"knowledge.title"},"style":"headline"},{"id":"selected-body","type":"text","binding":{"selection":"knowledge.content"}}]}]}]}"#
        app.views = try JSONDecoder().decode(NativeAppDefinition.Node.self, from: Data(nodeJSON.utf8))
        app.state = ["query": .init(initial: .string(""), persistent: true)]
        app.dataSources = ["knowledge": .init(kind: .knowledge, searchKey: "query", pageSize: 20)]
        app.actions = [:]
        try app.validate()
        return app
    }

    static let textStatisticsJSON = #"""
    {
      "manifest":{"id":"text-statistics","version":1,"dslVersion":2,"nameKey":"name","summaryKey":"summary","icon":"function","width":800,"height":680},
      "i18n":{
        "en":{"name":"Text Statistics","summary":"Analyze text with an approved offline Python function.","body":"Text","run":"Analyze","lines":"Lines","words":"Words"},
        "zh-Hans":{"name":"文本统计","summary":"通过经确认的离线 Python 函数分析文本。","body":"文本","run":"分析","lines":"行数","words":"词数"},
        "zh-Hant":{"name":"文字統計","summary":"透過經確認的離線 Python 函式分析文字。","body":"文字","run":"分析","lines":"行數","words":"詞數"},
        "es":{"name":"Estadísticas de texto","summary":"Analiza texto con una función de Python sin conexión y con aprobación.","body":"Texto","run":"Analizar","lines":"Líneas","words":"Palabras"},
        "fr":{"name":"Statistiques de texte","summary":"Analysez le texte avec une fonction Python hors ligne approuvée.","body":"Texte","run":"Analyser","lines":"Lignes","words":"Mots"},
        "ar":{"name":"إحصاءات النص","summary":"حلّل النص بدالة Python محلية بعد الموافقة.","body":"النص","run":"تحليل","lines":"الأسطر","words":"الكلمات"},
        "ru":{"name":"Статистика текста","summary":"Анализ текста одобренной локальной функцией Python.","body":"Текст","run":"Анализировать","lines":"Строки","words":"Слова"}
      },
      "state":{"body":{"initial":"","persistent":true},"lines":{"initial":0,"persistent":false},"words":{"initial":0,"persistent":false}},
      "dataSources":{},
      "scripts":{"analyze":{"source":"import json\nfrom pathlib import Path\n\ndef main(inputs, context):\n    text = inputs['text']\n    result = {'lines': len(text.splitlines()), 'words': len(text.split())}\n    Path(context['outputDirectory'], 'statistics.json').write_text(json.dumps(result), encoding='utf-8')\n    return result\n","inputTypes":{"text":"string"},"outputTypes":{"lines":"number","words":"number"},"requirements":[]}},
      "views":{"id":"root","type":"vstack","children":[
        {"id":"heading","type":"text","textKey":"name","style":"title"},
        {"id":"body","type":"textEditor","textKey":"body","stateKey":"body"},
        {"id":"run","type":"button","textKey":"run","action":"analyze"},
        {"id":"lines-row","type":"hstack","children":[{"id":"lines-label","type":"text","textKey":"lines"},{"id":"lines-value","type":"text","binding":{"state":"lines"}}]},
        {"id":"words-row","type":"hstack","children":[{"id":"words-label","type":"text","textKey":"words"},{"id":"words-value","type":"text","binding":{"state":"words"}}]}
      ]},
      "actions":{"analyze":{"type":"runPython","script":"analyze","inputs":{"text":{"state":"body"}},"resultBindings":{"lines":"lines","words":"words"}}}
    }
    """#

    static let noteJSON = #"""
    {
      "manifest":{"id":"quick-note","version":2,"dslVersion":1,"dataVersion":1,"nameKey":"name","summaryKey":"summary","icon":"square.and.pencil","width":880,"height":720},
      "i18n":{
        "en":{"name":"Quick Note","summary":"Keep private notes in this app; publish to Knowledge when needed.","title":"Title","body":"Content","save":"Publish to Knowledge","search":"Search notes","local-save":"Save Note","new":"New Note","edit":"Edit Selected","delete":"Delete Selected"},
        "zh-Hans":{"name":"随手记","summary":"在此应用中独立保存笔记，需要时再发布到知识库。","title":"标题","body":"内容","save":"发布到知识库","search":"搜索笔记","local-save":"保存笔记","new":"新建笔记","edit":"编辑所选笔记","delete":"删除所选笔记"},
        "zh-Hant":{"name":"隨手記","summary":"在此應用程式中獨立儲存筆記，需要時再發佈到知識庫。","title":"標題","body":"內容","save":"發佈到知識庫","search":"搜尋筆記","local-save":"儲存筆記","new":"新增筆記","edit":"編輯所選筆記","delete":"刪除所選筆記"},
        "es":{"name":"Nota rápida","summary":"Guarda notas en esta aplicación y publícalas en Conocimiento cuando lo necesites.","title":"Título","body":"Contenido","save":"Publicar en Conocimiento","search":"Buscar notas","local-save":"Guardar nota","new":"Nueva nota","edit":"Editar selección","delete":"Eliminar selección"},
        "fr":{"name":"Note rapide","summary":"Conservez vos notes dans cette application et publiez-les dans les connaissances au besoin.","title":"Titre","body":"Contenu","save":"Publier dans les connaissances","search":"Rechercher des notes","local-save":"Enregistrer la note","new":"Nouvelle note","edit":"Modifier la sélection","delete":"Supprimer la sélection"},
        "ar":{"name":"ملاحظة سريعة","summary":"احفظ ملاحظاتك في هذا التطبيق وانشرها في المعرفة عند الحاجة.","title":"العنوان","body":"المحتوى","save":"نشر في المعرفة","search":"البحث في الملاحظات","local-save":"حفظ الملاحظة","new":"ملاحظة جديدة","edit":"تعديل المحدد","delete":"حذف المحدد"},
        "ru":{"name":"Быстрая заметка","summary":"Храните заметки в этом приложении и при необходимости публикуйте их в базе знаний.","title":"Заголовок","body":"Содержимое","save":"Опубликовать в базе знаний","search":"Поиск заметок","local-save":"Сохранить заметку","new":"Новая заметка","edit":"Изменить выбранное","delete":"Удалить выбранное"}
      },
      "state":{"title":{"initial":"","persistent":true},"body":{"initial":"","persistent":true},"notes-query":{"initial":"","persistent":false}},
      "dataSources":{"notes":{"kind":"records","collection":"notes","searchKey":"notes-query","pageSize":20}},
      "views":{"id":"root","type":"vstack","children":[
        {"id":"heading","type":"text","textKey":"name","style":"title"},
        {"id":"columns","type":"hstack","children":[
          {"id":"sidebar","type":"vstack","children":[
            {"id":"search-notes","type":"textField","textKey":"search","stateKey":"notes-query"},
            {"id":"notes","type":"list","source":"notes"},
            {"id":"new","type":"button","textKey":"new","action":"new"},
            {"id":"edit","type":"button","textKey":"edit","action":"edit"},
            {"id":"delete","type":"button","textKey":"delete","action":"delete"}
          ]},
          {"id":"editor","type":"vstack","children":[
            {"id":"title","type":"textField","textKey":"title","stateKey":"title"},
            {"id":"body","type":"textEditor","textKey":"body","stateKey":"body"},
            {"id":"local-save","type":"button","textKey":"local-save","action":"local-save"},
            {"id":"save","type":"button","textKey":"save","action":"save"}
          ]}
        ]}
      ]},
      "actions":{
        "save":{"type":"saveKnowledge","values":{"title":{"state":"title"},"content":{"state":"body"}}},
        "local-save":{"type":"saveRecord","source":"notes","values":{"title":{"state":"title"},"content":{"state":"body"}}},
        "new":{"type":"newRecord","source":"notes","fields":{"title":"title","content":"body"}},
        "edit":{"type":"editRecord","source":"notes","fields":{"title":"title","content":"body"}},
        "delete":{"type":"deleteRecord","source":"notes"}
      }
    }
    """#
}
