import Foundation

extension NativeAppTemplates {
    public static func databaseMetadata() throws -> NativeAppDefinition {
        try NativeAppDefinition.decode(Data(databaseMetadataJSON.utf8))
    }

    static let databaseMetadataJSON = #"""
    {
      "manifest":{"id":"database-metadata","version":1,"dslVersion":3,"nameKey":"name","summaryKey":"summary","icon":"externaldrive.connected.to.line.below","width":1100,"height":800},
      "i18n":{
        "en":{"name":"Database Metadata","summary":"Browse MySQL schema using a host-managed connection and export metadata.","connection":"Database connection","tables":"Load tables","describe":"Inspect selected table and export","copy":"Copy summary","fields":"Fields","preview":"Summary"},
        "zh-Hans":{"name":"数据库元数据","summary":"通过宿主管理的连接浏览 MySQL 表结构并导出元数据。","connection":"数据库连接","tables":"加载表列表","describe":"查看所选表并导出","copy":"复制摘要","fields":"字段数","preview":"摘要"},
        "zh-Hant":{"name":"資料庫中繼資料","summary":"透過宿主管理的連線瀏覽 MySQL 資料表結構並匯出中繼資料。","connection":"資料庫連線","tables":"載入資料表清單","describe":"檢視所選資料表並匯出","copy":"複製摘要","fields":"欄位數","preview":"摘要"}
      },
      "state":{"field-count":{"initial":0,"persistent":false},"preview":{"initial":"","persistent":false}},
      "capabilities":{
        "tables":{"name":"database.tables","version":1,"resource":"database"},
        "columns":{"name":"database.columns","version":1,"resource":"database"},
        "copy":{"name":"clipboard.writeText","version":1}
      },
      "dataSources":{"tables":{"kind":"result","pageSize":50},"columns":{"kind":"result","pageSize":50}},
      "scripts":{"export":{"source":"import json\nfrom pathlib import Path\n\ndef main(inputs, context):\n    data = context['data']['columns']\n    Path(context['outputDirectory'], 'metadata.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')\n    text = '\\n'.join(row['fields']['name'] + ': ' + row['fields']['type'] for row in data['rows'])\n    return {'count': len(data['rows']), 'preview': text[:8000]}\n","inputTypes":{},"outputTypes":{"count":"number","preview":"string"}}},
      "views":{"id":"root","type":"vstack","children":[
        {"id":"title","type":"text","textKey":"name","style":"title"},
        {"id":"connection","type":"resourcePicker","textKey":"connection","resource":"database"},
        {"id":"controls","type":"hstack","children":[
          {"id":"load","type":"button","textKey":"tables","action":"load-tables"},
          {"id":"describe","type":"button","textKey":"describe","action":"inspect"},
          {"id":"copy","type":"button","textKey":"copy","action":"copy"}
        ]},
        {"id":"data","type":"hstack","children":[{"id":"tables","type":"list","source":"tables"},{"id":"columns","type":"table","source":"columns"}]},
        {"id":"count-label","type":"text","textKey":"fields"},
        {"id":"count","type":"text","binding":{"state":"field-count"}},
        {"id":"preview","type":"text","binding":{"state":"preview"}}
      ]},
      "actions":{
        "load-tables":{"type":"callCapability","capability":"tables","inputs":{},"source":"tables"},
        "load-columns":{"type":"callCapability","capability":"columns","inputs":{"table":{"selection":"tables.title"}},"source":"columns"},
        "export":{"type":"runPython","script":"export","inputs":{},"dataInputs":{"columns":"columns"},"resultBindings":{"field-count":"count","preview":"preview"}},
        "inspect":{"type":"sequence","steps":["load-columns","export"]},
        "copy":{"type":"callCapability","capability":"copy","inputs":{"text":{"state":"preview"}}}
      }
    }
    """#
}
